#!/usr/bin/env bash
# Bootstrap the ucm codebase on first run, compile the frontend to
# bytecode, then run it. run.compiled skips the codebase open and
# the typecheck, so startup drops from ~4s to well under a second.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v ucm >/dev/null; then
  echo "ucm not found. Run: nix develop (or nix shell nixpkgs#unison-ucm)" >&2
  exit 1
fi

# Sync the generated nixpkgs index into the codebase. The index is
# a plain Unison value; `update` makes it visible to the compiler.
sync_index() {
  printf 'load src/nixpkgs-index.u\nupdate\n' | ucm -c .ucm >/dev/null
}

if [ ! -d .ucm ]; then
  echo "First run: creating codebase and installing libraries ..." >&2
  ucm transcript -S .ucm setup.md
  sync_index
fi

# Recompile when the sources change. The stamp covers both source
# files; ./run.sh index regenerates the index file, which makes the
# stamp stale and triggers a recompile on the next run.
cache=.ucm-compiled
cur=$(cat src/upkg.u src/nixpkgs-index.u | sha256sum | cut -d' ' -f1)
if [ ! -f "$cache/upkg.uc" ] || [ "$(cat "$cache/stamp" 2>/dev/null)" != "$cur" ]; then
  echo "Compiling frontend ..." >&2
  mkdir -p "$cache"
  out=$(printf 'load src/upkg.u\nupdate\ncompile upkg.main %s\ncompile upkg.test.main %s\ncompile upkg.Sh.runner %s\n' \
    "$cache/upkg" "$cache/test" "$cache/runner" | ucm -c .ucm 2>&1) || true
  # ucm exits 0 even when the load fails; without this check, compile
  # would silently emit bytecode for the stale codebase version.
  if echo "$out" | grep -qE 'reserved keyword|I got confused|I was surprised|Typechecking failed|could not|blocked'; then
    echo "$out" >&2
    echo "compile failed: src/upkg.u has errors" >&2
    exit 1
  fi
  if [ ! -f "$cache/upkg.uc" ] || [ "$cache/upkg.uc" -ot src/upkg.u ]; then
    echo "$out" >&2
    echo "compile failed" >&2
    exit 1
  fi
  echo "$cur" > "$cache/stamp"
fi

case "${1:-}" in
  test)  exec ucm run.compiled "$cache/test.uc" ;;
  index) ucm run.compiled "$cache/upkg.uc" index
         sync_index
         echo "index synced into codebase" ;;
  *)     exec ucm run.compiled "$cache/upkg.uc" "$@" ;;
esac
