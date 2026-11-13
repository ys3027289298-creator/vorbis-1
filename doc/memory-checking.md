# Memory checking for libvorbis

This document describes the memory-safety checks wired into the repository
and the leak they were added to catch. All commands run without root and use
only the repository's own CMake test entry points.

## One-command reproduction

```sh
scripts/check-all.sh
```

This runs, in order:

1. `scripts/run-memory-check.sh` - the full test suite under memory checkers.
2. `scripts/verify-output-identity.sh` - byte-for-byte comparison of the
   library output before and after the fix.

The scripts provision their own dependencies under `$HOME/.local` (or an
existing `/home/ys/local` toolchain when present), so they work on a machine
without system `libogg-dev` or a system `valgrind`.

## What the checks run

The repository test suite (`test/vorbis_test`, `test/test_codebook`) is the
entry point. `vorbis_test` generates a small windowed-sine signal itself and
exercises the complete encode + decode path for
`8 channels x 11 quality steps x 6 sample rates = 528` cases.

- **AddressSanitizer + UndefinedBehaviorSanitizer + LeakSanitizer**
  (`-fsanitize=address,undefined`, LSan enabled). Any heap/stack overflow,
  use-after-free, or leak aborts the run.
- **valgrind memcheck** (`--leak-check=full --error-exitcode=99`) as an
  independent cross-check on a separate, non-instrumented build.

A clean run reports no sanitizer diagnostics, no `definitely`/`indirectly
lost` blocks, and a balanced alloc/free count.

### Tool deployment on a locked-down host

The scripts never require root. When `libogg-dev` or `valgrind` are not
installed system-wide, `scripts/toolchain.sh` downloads the packages through
the host's configured package proxy and unpacks them under `$HOME/.local`
(or reuses an existing `/home/ys/local` toolchain). valgrind additionally
needs glibc debug info whose version exactly matches the installed libc6, and
on this host it is launched through `proot` so that debug info is visible at
valgrind's hard-coded `/usr/lib/debug` path.

AddressSanitizer/LeakSanitizer are the primary detector here: they run
natively and reliably. Under the `proot` virtualization used to launch the
locally deployed valgrind, memcheck can report a false "no leak" for a
specific heap layout (the pointer-overwrite pattern below), while the same
binary reliably reports the leak once a trivial allocation perturbs the
layout. The two detectors therefore serve different roles - LSan is
authoritative for leaks, valgrind provides an independent, zero-finding
cross-check on the fixed code.

## Leak fixed: encoder residue slot overwrite

`vorbis_encode_residue_setup()` stores each residue backend in a fixed slot,
`ci->residue_param[number]`. The short-block and long-block modes reuse the
same slot numbers (see the `residuesubmap` tables in `lib/modes/`). For
multi-submap streams (for example 5.1/6-channel and 7/8-channel modes), one
slot is configured twice for the same residue backend:

1. the first mode allocates the slot and stores pointer A;
2. the second mode allocates a new object and overwrites the slot with
   pointer B, without releasing A;
3. `vorbis_info_clear()` walks each slot once and frees only B, so A leaks.

The bug is data dependent, which is why it only surfaced on the higher
channel-count cases of the full matrix rather than the first test. Across the
whole 528-case run the pre-fix build leaked 62,656 bytes in 22 allocations;
the first single-slot leak is 2,848 bytes.

The fix (`lib/vorbisenc.c`) releases the previous object through the residue
backend's own `free_info` before the slot is reconfigured, but only when the
slot already exists and uses the same backend type. The object that remains
resident after setup is exactly the one the original code left in place, so
the encoded stream and every decoded sample are unchanged.

## Output identity

`scripts/verify-output-identity.sh` builds the pristine `HEAD` library in a
temporary git worktree and the current library, then for all 528 parameter
combinations asserts both:

- the encoded Ogg/Vorbis files are byte-identical, and
- the decoded little-endian float PCM is byte-identical sample for sample.

Any difference fails the script, giving a hard guarantee that the leak fix
does not alter library output.
