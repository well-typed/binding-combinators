#!/usr/bin/env bash
#
# generate-and-run.sh
#
# This example builds over libclang's RAW Clang.LowLevel.FFI. Upstream
# libclang-bindings keeps that module (and the Clang.Internal.* /
# Clang.LowLevel.Core.* plumbing it is written in terms of) as an other-module,
# so a dependent package cannot import the substrate at all. We therefore build
# against a local copy of libclang-bindings with those modules re-exposed, at
# ../libclang-bindings, where cabal.project points.
#
# That copy is a build dependency, not part of this project, so only hs-project/
# is committed and this script materialises the dependency: it fetches the pinned
# libclang-bindings source, re-exposes the raw substrate, then builds and runs
# both demos and checks their output is byte-identical.
#
# Run it with GHC, cabal, and libclang / llvm-config on PATH, exactly as
# `cabal build` here needs. The pin below must be a revision whose API matches the
# index-state in cabal.project.
set -euo pipefail

REPO="https://github.com/well-typed/libclang-bindings"
TAG="ef67437045c45a32d7d1aa7166043937c1259d7f"
SUBDIR="libclang-bindings"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="$(cd "$HERE/.." && pwd)/libclang-bindings"

# Upstream lists these under other-modules; re-expose them so we can import the
# raw FFI. This is the only change we make to the pinned source.
SUBSTRATE="\
Clang.Internal.ConstPtr \
Clang.Internal.CXString \
Clang.Internal.Results \
Clang.LowLevel.Core.Enums \
Clang.LowLevel.Core.Instances \
Clang.LowLevel.Core.Pointers \
Clang.LowLevel.Core.Structs \
Clang.LowLevel.FFI"

reexpose() {
  # Insert the substrate modules right after the exposed-modules: header and drop
  # them from wherever they currently sit (the other-modules block).
  local cabal="$1"
  awk -v subs="$SUBSTRATE" '
    BEGIN { n = split(subs, a, " "); for (i = 1; i <= n; i++) drop[a[i]] = 1 }
    { name = $0; sub(/^[[:space:]]+/, "", name) }
    /^[[:space:]]*exposed-modules:/ {
      print
      for (i = 1; i <= n; i++) print "    " a[i]
      next
    }
    (name in drop) { next }
    { print }
  ' "$cabal" > "$cabal.reexposed" && mv "$cabal.reexposed" "$cabal"
}

if [ -f "$VENDOR/libclang-bindings.cabal" ]; then
  echo ">> Using existing $VENDOR"
else
  echo ">> Fetching libclang-bindings @ ${TAG:0:12} from $REPO"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  git clone --quiet --filter=blob:none --no-checkout "$REPO" "$tmp/repo"
  git -C "$tmp/repo" checkout --quiet "$TAG"
  mkdir -p "$VENDOR"
  cp -a "$tmp/repo/$SUBDIR/." "$VENDOR/"
  rm -rf "$VENDOR/dist-newstyle" "$VENDOR/dist"
  echo ">> Re-exposing the raw substrate in libclang-bindings.cabal"
  reexpose "$VENDOR/libclang-bindings.cabal"
fi

cd "$HERE"

echo ">> Building demos ..."
cabal build libclang-ffi-walk-high libclang-ffi-walk-low

echo ">> Running demos on fixture.h ..."
high="$(cabal -v0 run libclang-ffi-walk-high -- fixture.h)"
low="$(cabal -v0 run libclang-ffi-walk-low -- fixture.h)"

if [ "$high" = "$low" ]; then
  echo ">> OK: the high- and low-level walks produce byte-identical output:"
  printf '%s\n' "$high" | sed 's/^/     /'
else
  echo "!! MISMATCH between the high- and low-level walks:" >&2
  diff <(printf '%s\n' "$low") <(printf '%s\n' "$high") >&2
  exit 1
fi
