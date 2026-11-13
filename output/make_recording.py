#!/usr/bin/env python3
"""Build the segmented demo recording from real verification artifacts.

Pipeline:
  1. Drive real commands inside tmux (record_session.sh style) and snapshot
     the pane after each step.
  2. Render every snapshot to a PNG with a per-segment title bar.
  3. Hold title cards and add pauses between segments, then encode to MP4
     with ffmpeg at a fixed frame rate.

All displayed output comes from commands actually executed in this checkout;
the long full-suite logs are replayed through `cat`/`tail` so the recording
stays short while showing genuine results.
"""
import os
import shutil
import subprocess
import sys

REPO = "/home/ys/feedback/uidreczz28ZAeUf6VCJ"
WORK = os.path.join(REPO, "output", "rec_work")
FRAMES = os.path.join(WORK, "frames")
SESSION = "recmem2"
COLS, ROWS = 118, 40
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
FPS = 12
CANVAS = (1760, 1180)
TITLE_HOLD = 2.4   # seconds held on the first frame of each segment
STEP_HOLD = 1.7    # seconds each command-result frame stays visible


def run(cmd, check=True):
    print("$", cmd)
    return subprocess.run(cmd, shell=isinstance(cmd, str), check=check,
                          cwd=REPO)


def tmux(args):
    subprocess.run(["tmux"] + args, check=True)


class Recorder:
    def __init__(self):
        shutil.rmtree(WORK, ignore_errors=True)
        os.makedirs(FRAMES, exist_ok=True)
        subprocess.run(["tmux", "kill-session", "-t", SESSION],
                       stderr=subprocess.DEVNULL)
        tmux(["new-session", "-d", "-s", SESSION, "-x", str(COLS),
              "-y", str(ROWS), "-c", REPO])
        self.n = 0
        self._send("clear")
        self._key("Enter")

    def _send(self, text):
        tmux(["send-keys", "-t", SESSION, text])

    def _key(self, key):
        tmux(["send-keys", "-t", SESSION, key])

    def type_run(self, command, settle=1.2):
        """Type a command visibly and execute it."""
        self._send(command)
        self._key("Enter")
        self._idle(settle)

    def _idle(self, seconds):
        # Poll so commands that finish quickly still get a stable snapshot.
        subprocess.run(["sleep", str(seconds)])

    def snapshot(self, title):
        cap = os.path.join(WORK, f"cap-{self.n:04d}.txt")
        tmux(["capture-pane", "-t", SESSION, "-e", "-p"])
        data = subprocess.run(["tmux", "capture-pane", "-t", SESSION,
                               "-e", "-p"], check=True,
                              capture_output=True, text=True).stdout
        with open(cap, "w") as fh:
            fh.write(data)
        png = os.path.join(FRAMES, f"frame-{self.n:04d}.png")
        subprocess.run([sys.executable,
                        os.path.join(REPO, "output", "render_terminal.py"),
                        cap, png, "--font", FONT, "--title", title],
                       check=True)
        self.n += 1
        return self.n - 1

    def close(self):
        subprocess.run(["tmux", "kill-session", "-t", SESSION],
                       stderr=subprocess.DEVNULL)


def main():
    rec = Recorder()
    # (title, command, settle seconds). Commands are real; long outputs are
    # taken from logs produced by scripts/check-all.sh. The screen is cleared
    # at each segment boundary so a frame never mixes two segments.
    steps = [
        ("1/6 Repository and check entry points",
         "git log --oneline -1 && ls scripts/", 1.2),
        ("1/6 Repository and check entry points",
         "sed -n '1,20p' scripts/check-all.sh", 1.0),
        ("2/6 Leak found by AddressSanitizer (pre-fix build)",
         "grep -E 'LeakSanitizer|vorbisenc.c|SUMMARY' output/logs/asan-prefix-leak.log | head -8", 1.2),
        ("3/6 Root cause: residue slot overwrite in vorbisenc.c",
         "sed -n '456,480p' lib/vorbisenc.c", 1.2),
        ("3/6 Root cause: residue slot overwrite in vorbisenc.c",
         "git diff lib/vorbisenc.c | sed -n '1,40p'", 1.2),
        ("4/6 Full suite under ASan/UBSan/LSan: 528 cases, zero findings",
         "grep -E 'Running full encode|RESULT' output/logs/memory-check.log", 1.2),
        ("5/6 Independent valgrind memcheck cross-check",
         "grep -A3 'under valgrind memcheck' output/logs/memory-check.log | tail -6", 1.2),
        ("6/6 Output identity: Ogg bytes and decoded PCM unchanged",
         "grep -E 'IDENTITY|ALL CHECKS' output/logs/check-all.log", 1.2),
    ]

    # (frame_index, hold_seconds). First frame of each segment is held longer
    # to act as a visible title card and inter-segment pause.
    schedule = []
    last_title = None
    for title, cmd, settle in steps:
        if title != last_title:
            last_title = title
            is_segment_start = True
            rec.type_run("clear", 0.5)
            rec.type_run(f"printf '\\n### {title} ###\\n'", 0.6)
        else:
            is_segment_start = False
        rec.type_run(cmd, settle)
        idx = rec.snapshot(title)
        schedule.append((idx, TITLE_HOLD if is_segment_start else STEP_HOLD))

    rec.close()

    # Build an ffmpeg concat list holding each frame for its scheduled time.
    concat = os.path.join(WORK, "concat.txt")
    with open(concat, "w") as fh:
        for idx, hold in schedule:
            png = os.path.join(FRAMES, f"frame-{idx:04d}.png")
            fh.write(f"file '{png}'\n")
            fh.write(f"duration {hold}\n")
        # ffmpeg concat demuxer requires the last file repeated.
        last_png = os.path.join(FRAMES, f"frame-{schedule[-1][0]:04d}.png")
        fh.write(f"file '{last_png}'\n")

    out = os.path.join(REPO, "output", "memory-check-demo.mp4")
    subprocess.run([
        "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", concat,
        "-vf", f"fps={FPS},format=yuv420p",
        "-c:v", "libx264", "-preset", "medium", "-crf", "20",
        out,
    ], check=True)
    print("wrote", out)


if __name__ == "__main__":
    main()
