# Verification artifacts

Everything in this directory is produced by the repository's own scripts; it
can be regenerated without manual interaction.

## Recording

- `memory-check-demo.mp4` - segmented screen recording (no keyboard waiting).
  Six titled segments with pauses between them:
  1. repository and one-command check entry points
  2. leak reported by AddressSanitizer on the pre-fix build
  3. root cause and the `lib/vorbisenc.c` fix
  4. full 528-case encode/decode suite under ASan/UBSan/LSan
  5. independent valgrind memcheck cross-check
  6. output identity (Ogg bytes + decoded PCM) and final result

  Regenerate with:

  ```sh
  python3 output/make_recording.py
  ```

  The recording drives real commands in `tmux`, snapshots the pane, and
  renders the frames with `render_terminal.py` (Pillow + ffmpeg). The
  intermediate frames live in `rec_work/` and are safe to delete.

## Logs (`logs/`)

- `asan-prefix-leak.log` - the pre-fix AddressSanitizer/LeakSanitizer report
  proving the leak (62,656 bytes in 22 allocations).
- `memory-check.log` - sanitizer + valgrind run of the full test suite.
- `output-identity.log` - the byte-identity verification summary.
- `check-all.log` - complete output of the single `scripts/check-all.sh`
  entry point, from a clean build.

The raw commands behind all logs are the checked-in scripts under
`scripts/`; see `doc/memory-checking.md` for details.
