#!/usr/bin/env bash
# Bootstrap the ucm codebase on first run, then run the frontend.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v ucm >/dev/null; then
  echo "ucm not found. Run: nix develop (or nix shell nixpkgs#unison-ucm)" >&2
  exit 1
fi

# Sync the generated nixpkgs index into the codebase. The index is
# a plain Unison value; `update` makes it visible to run.file.
sync_index() {
  printf 'load src/nixpkgs-index.u\nupdate\n' | ucm -c .ucm >/dev/null
}

if [ ! -d .ucm ]; then
  echo "First run: creating codebase and installing libraries ..." >&2
  ucm transcript -S .ucm setup.md
  sync_index
fi

case "${1:-}" in
  test)  exec ucm -c .ucm run.file src/unix.u unix.test.main ;;
  index) ucm -c .ucm run.file src/unix.u unix.main index
         sync_index
         echo "index synced into codebase" ;;
  *)     exec ucm -c .ucm run.file src/unix.u unix.main "$@" ;;
esac
