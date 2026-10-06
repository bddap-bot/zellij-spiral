#!/usr/bin/env bash
# Release supply-chain check: no known vulnerability in Cargo.lock, and the
# workflows run only first-party actions pinned to a full commit SHA.
#
# Usage:  nix shell nixpkgs#cargo-audit nixpkgs#actionlint -c test/check-supply-chain.sh

set -u
cd "$(dirname "$0")/.." || exit
fail=0

cargo-audit audit --file Cargo.lock || fail=1
actionlint .github/workflows/*.y*ml || fail=1

# Any line mentioning `uses` must be a plain `uses: actions/<name>@<sha>`, so
# unusual YAML spellings fail closed rather than slipping past.
bad=$(grep -nH 'uses' .github/workflows/*.y*ml |
  grep -vE '^[^:]+:[0-9]+:\s*(-\s+)?uses:\s+actions/[A-Za-z0-9_.-]+@[0-9a-f]{40}(\s+#.*)?$')
if [ -n "$bad" ]; then
  echo "every uses: must be actions/* pinned to a 40-hex commit SHA:" >&2
  echo "$bad" >&2
  fail=1
fi

exit "$fail"
