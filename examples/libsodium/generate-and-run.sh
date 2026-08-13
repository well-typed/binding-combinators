#!/usr/bin/env bash
#
# Generate low-level libsodium bindings (one module per header, in topological
# order), wire up the cabal package, build, and run the demo programs.
#
# The header order is derived from the tool, not hand-curated: we ask
# `hs-bindgen-cli info include-graph` for the include DAG, then `tsort` it so
# that a header is always generated after every header it depends on. Each pass
# feeds the binding specs of all previously generated headers as
# `--external-binding-spec`, so cross-header types (the opaque state structs, the
# primitive-header constants, ...) resolve to the module that already defines them.
#
# Generation is resilient: a header that fails to generate is logged and skipped
# (what breaks at this scale is itself a finding), so the run continues.
#
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# libsodium, pinned to a release tag so the example is reproducible. We fetch it
# on demand rather than as a git submodule: a submodule is cloned by cabal for
# every project that depends on this repository via source-repository-package,
# even though only the library at the repository root is needed.
LIBSODIUM_REPO="https://github.com/jedisct1/libsodium"
LIBSODIUM_TAG="1.0.22-RELEASE"

SRC="$SCRIPT_DIR/libsodium"
PREFIX="$SRC/build-prefix"
INCLUDE_DIR="$PREFIX/include"
LIB_DIR="$PREFIX/lib"
BINDING_SPEC_DIR="$SCRIPT_DIR/binding-specs"
HS_OUTPUT_DIR="$SCRIPT_DIR/hs-project/src"
CABAL_FILE="$SCRIPT_DIR/hs-project/libsodium.cabal"
GRAPH="$SCRIPT_DIR/include-graph.mmd"
GENLOG_DIR="$SCRIPT_DIR/gen-logs"

# Headers we deliberately do not generate. Populated as failures are triaged.
SKIP=""

# snake_case header -> CamelCase module suffix (crypto_secretbox.h -> CryptoSecretbox)
camel() { echo "${1%.h}" | sed -E 's/(^|_)([a-z])/\U\2/g'; }

# -----------------------------------------------------------------------------
# 0. Prerequisites: pinned source fetched, libsodium built and installed.
# -----------------------------------------------------------------------------
# -e (not -d): a prior submodule checkout leaves .git as a gitlink file, which is
# still a usable clone, so only clone when nothing is there.
if [ ! -e "$SRC/.git" ]; then
  # --filter=blob:none keeps the download small (blobs are fetched on demand)
  # while still allowing checkout of the pinned tag; a shallow clone could not
  # check out an arbitrary older tag.
  git clone --filter=blob:none "$LIBSODIUM_REPO" "$SRC" || exit 1
fi
git -C "$SRC" checkout --quiet "$LIBSODIUM_TAG" || exit 1

if ! ls "$LIB_DIR"/libsodium.so* >/dev/null 2>&1; then
  echo "==> libsodium not built yet; building it"
  "$SCRIPT_DIR/build-libsodium.sh" || exit 1
fi

mkdir -p "$BINDING_SPEC_DIR" "$HS_OUTPUT_DIR" "$GENLOG_DIR"

cd "$SCRIPT_DIR"

# hs-bindgen-cli. Prefer an explicit override, then one already on PATH, and only fall
# back to building the hs-bindgen pinned by hs-project/cabal.project, which is slow: it
# drags in the generator's whole dependency closure and needs libclang.
CLI="${HS_BINDGEN_CLI:-}"
if [ -n "$CLI" ] && [ ! -x "$CLI" ]; then
  echo "HS_BINDGEN_CLI is set to '$CLI', which is not an executable file" >&2
  exit 1
fi
if [ -z "$CLI" ] && command -v hs-bindgen-cli >/dev/null 2>&1; then
  CLI="$(command -v hs-bindgen-cli)"
fi
if [ -z "$CLI" ]; then
  echo "==> no hs-bindgen-cli found; building the pinned one (set HS_BINDGEN_CLI to skip)"
  ( cd "$SCRIPT_DIR/hs-project" && cabal build hs-bindgen-cli ) || exit 1
  CLI="$( cd "$SCRIPT_DIR/hs-project" && cabal list-bin hs-bindgen-cli )" || exit 1
fi
echo "==> using hs-bindgen-cli at $CLI"

# -----------------------------------------------------------------------------
# 1. Include graph -> topological order (dependencies first).
# -----------------------------------------------------------------------------
echo "==> Computing include graph"
rm -f "$GRAPH"   # info include-graph will not overwrite an existing output file
"$CLI" info include-graph -I "$INCLUDE_DIR" --show-paths -o "$GRAPH" sodium.h || exit 1

# Mermaid format (Data/DynGraph/Labelled.hs:dumpMermaid):
#   graph TD;
#     v<id>("<path>")          node
#     v<a>-->v<b>              edge: a includes b  =>  b is a dependency of a
#     v<a>-.->v<b>             (transient include)
# Keep only per-family headers under .../include/sodium/<name>.h (the umbrella
# sodium.h just aggregates them). For tsort we print "<dep> <dependent>".
awk '
  match($0, /^  v([0-9]+)\("(.*)"\)$/, m) {
    id=m[1]; path=m[2]
    if (path ~ /\/include\/sodium\/[^/]+\.h$/) {
      n=split(path, p, "/"); name[id]=p[n]; isg[id]=1
    }
    next
  }
  match($0, /^  v([0-9]+)-\.?->v([0-9]+)$/, e) {
    if (isg[e[1]] && isg[e[2]]) print name[e[2]], name[e[1]]
    next
  }
  END { for (i in name) print name[i] > "/dev/stderr" }
' "$GRAPH" >"$SCRIPT_DIR/.edges" 2>"$SCRIPT_DIR/.nodes"

SORTED="$(tsort "$SCRIPT_DIR/.edges" 2>"$SCRIPT_DIR/.tsort.err")"
if [ -s "$SCRIPT_DIR/.tsort.err" ]; then
  echo "   note: tsort reported include cycles (still produced an order):"
  sed 's/^/     /' "$SCRIPT_DIR/.tsort.err"
fi
# Append isolated headers (present in no sodium<->sodium edge); order among them is free.
ISOLATED="$(comm -23 <(sort -u "$SCRIPT_DIR/.nodes") <(printf '%s\n' "$SORTED" | sort -u))"
ORDER="$(printf '%s\n%s\n' "$SORTED" "$ISOLATED" | sed '/^$/d')"

echo "==> Topological order ($(printf '%s\n' "$ORDER" | grep -c .) headers):"
printf '%s\n' "$ORDER" | sed 's/^/     /'

# -----------------------------------------------------------------------------
# 2. Generate one module per header, accumulating binding specs.
# -----------------------------------------------------------------------------
echo "==> Generating bindings"
SPECS=()
OK_COUNT=0
FAILED=""
for header in $ORDER; do
  case " $SKIP " in *" $header "*) echo "  skip $header"; continue;; esac
  mod="Generated.$(camel "$header")"
  spec="$BINDING_SPEC_DIR/${header%.h}.yaml"

  ext=()
  for s in "${SPECS[@]}"; do ext+=(--external-binding-spec "$s"); done

  if "$CLI" preprocess \
       -I "$INCLUDE_DIR" \
       --unique-id org.libsodium \
       --hs-output-dir "$HS_OUTPUT_DIR" \
       --create-output-dirs --overwrite-files \
       --module "$mod" \
       --select-from-main-headers --enable-program-slicing \
       --select-except-deprecated \
       --gen-binding-spec "$spec" \
       "${ext[@]}" \
       "sodium/$header" >"$GENLOG_DIR/${header%.h}.log" 2>&1; then
    echo "  ok   $header -> $mod"
    [ -f "$spec" ] && SPECS+=("$spec")
    OK_COUNT=$((OK_COUNT+1))
  else
    echo "  FAIL $header  (see gen-logs/${header%.h}.log)"
    FAILED="$FAILED $header"
  fi
done

echo "==> Generated $OK_COUNT header modules."
[ -n "$FAILED" ] && echo "==> Failed headers:$FAILED"

# -----------------------------------------------------------------------------
# 3. Rewrite the cabal file's exposed-modules from the file tree.
# -----------------------------------------------------------------------------
# Every module of the library, hand-written and generated alike, is a file under
# src/, so the whole exposed-modules field can be derived from the tree and written
# out sorted. Deriving the whole field rather than appending to a marker block is
# what keeps this idempotent: cabal-fmt normalises a marker block by moving the
# names it holds into exposed-modules proper, after which a second run of this
# script would add them a second time and cabal would reject the duplicates.
MODS="$( cd "$HS_OUTPUT_DIR" && find . -name '*.hs' \
          | sed -E 's#^\./##; s#/#.#g; s#\.hs$##' | LC_ALL=C sort | sed 's/^/    /' )"
awk -v list="$MODS" '
  # Replace the exposed-modules field: print the header and the derived list, then
  # drop the old entries (blank or more-indented lines) up to the next field.
  /^  exposed-modules:[[:space:]]*$/ { print; print list; inField=1; next }
  inField && /^[[:space:]]*$/        { next }
  inField && /^    /                 { next }
  inField                            { inField=0 }
                                     { print }
' "$CABAL_FILE" >"$CABAL_FILE.tmp" && mv "$CABAL_FILE.tmp" "$CABAL_FILE"
echo "==> Updated $CABAL_FILE exposed-modules."

# cabal-fmt owns the canonical ordering, and CI checks it. Run it when it is available
# so a generated cabal file is committable as-is; the file is correct either way.
if command -v cabal-fmt >/dev/null 2>&1; then
  cabal-fmt -i "$CABAL_FILE" && echo "==> Formatted $CABAL_FILE with cabal-fmt"
fi

# -----------------------------------------------------------------------------
# 4. Point cabal at the headers and the freshly built shared library.
# -----------------------------------------------------------------------------
cat >"$SCRIPT_DIR/hs-project/cabal.project.local" <<EOF
package libsodium
    extra-include-dirs: $INCLUDE_DIR
    extra-lib-dirs: $LIB_DIR
EOF
echo "==> Wrote cabal.project.local"

# -----------------------------------------------------------------------------
# 5. Build and (if present) run the demo programs.
# -----------------------------------------------------------------------------
cd "$SCRIPT_DIR/hs-project"
export LD_LIBRARY_PATH="$LIB_DIR:${LD_LIBRARY_PATH:-}"

echo "==> cabal build"
cabal build all || { echo "build failed"; exit 1; }

# Each demo is self-contained (no arguments); the low-level and high-level
# variants must print identical output.
echo "==> demos (low-level vs high-level)"
for demo in secretbox sign; do
  for variant in low high; do
    exe="libsodium-$demo-$variant"
    cabal list-bin "$exe" >/dev/null 2>&1 || continue
    echo "--- $exe ---"
    cabal run -v0 "$exe"
  done
done
