#!/usr/bin/env bash
# Run upkg on a LOCAL FORK of the whole stack: a ucm patched with
# daemon/af-unix.patch, plus a locally-forked @unison/base (base
# installed, the unixClientSocket builtin merged in isolation as
# lib.sockimpl). No base republish, no per-op ceremony -- upkg's own
# library talks to the nix-daemon over the socket.
#
# Needs the patched ucm. Point UPKG_UCM at its `unison` binary, or
# build it: nix build <unison-checkout-with-af-unix.patch>#unison-cli-main
set -euo pipefail
cd "$(dirname "$0")"

UCM="${UPKG_UCM:-}"
if [ -z "$UCM" ]; then
  echo "Set UPKG_UCM to a patched ucm (unison built with daemon/af-unix.patch)." >&2
  echo "e.g. UPKG_UCM=/nix/store/...-unison-cli-main-.../bin/unison ./run-forked.sh" >&2
  exit 1
fi

cb=.ucm-forked
lib="src/nixpkgs-index.u src/upkg/00-core.u src/upkg/01-model.u \
src/upkg/02-index.u src/upkg/03-ship.u src/upkg/04-plan.u src/upkg/05-drv.u \
src/upkg/06-cargo.u src/upkg/07-builders.u src/upkg/08-claims.u \
src/upkg/09-release.u src/upkg/10-typed.u \
daemon/nar.u daemon/nixd.u daemon/upkg-daemon.u"

# One transcript session: install base + forked-base socket merge,
# load the whole upkg library + daemon module, and run -- all in the
# same session (the patched ucm loses builtin types when reopening a
# saved codebase, so we never reopen). transcript.fork discards the
# codebase afterward; the point is the run.
{
  echo '```ucm'
  echo 'scratch/main> lib.install @unison/base'
  echo 'scratch/main> lib.install @unison/json'
  # the local fork of base: rescue the socket builtin, drop the rest
  echo 'scratch/main> builtins.mergeio lib.raw'
  echo 'scratch/main> move.term lib.raw.io2.IO.unixClientSocket.impl lib.sockimpl'
  echo 'scratch/main> delete.namespace lib.raw'
  for f in $lib; do echo "scratch/main> load $f"; echo 'scratch/main> add'; done
  echo 'scratch/main> run upkg.daemon.main'
  echo '```'
} > .forked.md
echo "Running upkg on the local fork (patched ucm + forked base) ..." >&2
"$UCM" transcript.fork -S "$cb" .forked.md 2>&1 \
  | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -E 'local fork|index hello|valid via|added via|nixd error' || true
