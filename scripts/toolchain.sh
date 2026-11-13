#!/usr/bin/env bash
#
# toolchain.sh - locate or locally provision the dependencies needed to
# build libvorbis and run its memory checks, without requiring root.
#
# This script is sourced by the other scripts in this directory. It exports:
#   OGG_INCLUDE_DIR, OGG_LIBRARY   - static libogg used for the CMake build
#   HAVE_VALGRIND                  - "1" when a working valgrind is available
#   valgrind_run <cmd...>          - run a command under memcheck when present
#
# Everything is installed under $LOCAL_PREFIX (default: $HOME/.local), so the
# whole flow works offline once the packages are cached, and also behind the
# environment's HTTP proxy when packages have to be downloaded.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_PREFIX="${LOCAL_PREFIX:-$HOME/.local}"

# Tools may already be provisioned in a shared location (for example
# /home/ys/local); search a few candidate roots before downloading anything.
PREFIX_CANDIDATES=("$LOCAL_PREFIX" "/home/ys/local" "/usr/local")

find_dir() {
  local rel="$1"
  local d
  for d in "${PREFIX_CANDIDATES[@]}"; do
    [[ -e "$d/$rel" ]] && { echo "$d/$rel"; return 0; }
  done
  return 1
}

OGG_DEV_DIR="$(find_dir oggdev || echo "$LOCAL_PREFIX/oggdev")"
VALGRIND_DIR="$(find_dir valgrind || echo "$LOCAL_PREFIX/valgrind")"
LIBC6DBG_DIR="$(find_dir libc6dbg9 || echo "$LOCAL_PREFIX/libc6dbg9")"
PROOT_DIR="$(find_dir proot || echo "$LOCAL_PREFIX/proot")"

HAVE_VALGRIND=0
VG_BIN=""

log() { printf '[toolchain] %s\n' "$*"; }

# --- libogg (headers + static library) -------------------------------------
provision_ogg() {
  if [[ -f "$OGG_DEV_DIR/usr/include/ogg/ogg.h" && \
        -f "$OGG_DEV_DIR/usr/lib/x86_64-linux-gnu/libogg.a" ]]; then
    log "using provisioned libogg under $OGG_DEV_DIR"
  else
    log "provisioning libogg into $OGG_DEV_DIR"
    mkdir -p "$LOCAL_PREFIX/ogg-deb"
    ( cd "$LOCAL_PREFIX/ogg-deb" && apt-get download libogg-dev )
    mkdir -p "$OGG_DEV_DIR"
    dpkg-deb -x "$LOCAL_PREFIX"/ogg-deb/libogg-dev_*.deb "$OGG_DEV_DIR"
  fi
  OGG_INCLUDE_DIR="$OGG_DEV_DIR/usr/include"
  OGG_LIBRARY="$OGG_DEV_DIR/usr/lib/x86_64-linux-gnu/libogg.a"
  export OGG_INCLUDE_DIR OGG_LIBRARY
}

# --- valgrind (no-root, plus the matching glibc debug info) ----------------
# valgrind needs the non-stripped ld.so/glibc debug info. The host libc6 and
# the libc6-dbg package must match exactly; the version is detected from the
# installed libc6. On this machine valgrind also has to run under proot so the
# debug info is visible at its hard-coded /usr/lib/debug location.
provision_valgrind() {
  HAVE_VALGRIND=0
  command -v valgrind >/dev/null 2>&1 && HAVE_VALGRIND=1

  VG_BIN="$VALGRIND_DIR/usr/bin/valgrind"
  if [[ "$HAVE_VALGRIND" -eq 0 && -x "$VG_BIN" ]]; then
    if [[ ! -x "$VALGRIND_DIR/usr/libexec/valgrind/memcheck-amd64-linux" ]]; then
      log "valgrind payload incomplete; skipping memcheck"
      return
    fi
    if [[ ! -d "$LIBC6DBG_DIR/usr/lib/debug" ]]; then
      log "provisioning matching libc6-dbg for valgrind"
      local libc_ver
      libc_ver="$(dpkg-query -W -f='${Version}' libc6:amd64 2>/dev/null || true)"
      mkdir -p "$LOCAL_PREFIX/libc-dbg-deb"
      ( cd "$LOCAL_PREFIX/libc-dbg-deb" && \
        apt-get download "libc6-dbg=$libc_ver" )
      mkdir -p "$LIBC6DBG_DIR"
      dpkg-deb -x "$LOCAL_PREFIX"/libc-dbg-deb/libc6-dbg_*.deb "$LIBC6DBG_DIR"
    fi
    if [[ -z "$(_proot_path)" ]]; then
      log "proot unavailable; cannot launch local valgrind, skipping memcheck"
      return
    fi
    HAVE_VALGRIND=1
    log "using provisioned valgrind under $VALGRIND_DIR"
  fi
}

_proot_path() {
  if command -v proot >/dev/null 2>&1; then
    command -v proot
  elif [[ -x /tmp/xvfb_local/rootfs/usr/bin/proot ]]; then
    echo /tmp/xvfb_local/rootfs/usr/bin/proot
  fi
}

_proot_bin() { _proot_path; }

# Run a command under valgrind memcheck. Falls back to a direct system
# valgrind when one is on PATH; otherwise uses the no-root proot deployment.
valgrind_run() {
  if [[ "$HAVE_VALGRIND" -ne 1 ]]; then
    log "valgrind unavailable; running without memcheck: $*"
    "$@"
    return $?
  fi

  local common=( --quiet --error-exitcode=99 \
                 --errors-for-leak-kinds=definite,indirect \
                 --leak-check=full --show-leak-kinds=definite,indirect \
                 --track-origins=yes )

  if command -v valgrind >/dev/null 2>&1; then
    valgrind "${common[@]}" "$@"
    return $?
  fi

  local proot_bin proot_lib
  proot_bin="$(_proot_bin)"
  proot_lib="$PROOT_DIR/usr/lib/x86_64-linux-gnu"
  if [[ ! -d "$proot_lib" ]]; then
    local talloc
    talloc="$(find "${PREFIX_CANDIDATES[@]}" -name 'libtalloc.so.2' 2>/dev/null | head -1)"
    [[ -n "$talloc" ]] && proot_lib="$(dirname "$talloc")"
  fi
  if [[ -z "$proot_bin" || ! -x "$proot_bin" ]]; then
    log "proot launcher missing; running without memcheck: $*"
    "$@"
    return $?
  fi
  if [[ -d "$proot_lib" ]]; then
    VALGRIND_LIB="$VALGRIND_DIR/usr/libexec/valgrind" \
    LD_LIBRARY_PATH="$proot_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      "$proot_bin" \
        -b "$LIBC6DBG_DIR/usr/lib/debug:/usr/lib/debug" \
        "$VG_BIN" "${common[@]}" "$@"
  else
    VALGRIND_LIB="$VALGRIND_DIR/usr/libexec/valgrind" \
      "$proot_bin" \
        -b "$LIBC6DBG_DIR/usr/lib/debug:/usr/lib/debug" \
        "$VG_BIN" "${common[@]}" "$@"
  fi
}

provision_ogg
provision_valgrind

export HAVE_VALGRIND
