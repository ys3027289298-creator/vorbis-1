#!/usr/bin/env bash
#
# check-all.sh - one-command entry point for the complete verification.
#
#   1. memory checks  : full encode/decode + codebook suite under
#                       ASan/UBSan/LSan (and valgrind memcheck when present),
#                       requiring zero leaks and zero out-of-bounds access
#   2. output identity: byte-identical Ogg streams and decoded PCM samples
#                       versus the pristine pre-fix library, across all 528
#                       encode/decode parameter combinations
#
# Usage:  scripts/check-all.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$HERE/run-memory-check.sh"
"$HERE/verify-output-identity.sh"

printf '\n######## ALL CHECKS PASSED ########\n'
