#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Writes the lockfiles of the negative tests from the lockfile of
# tests/fixtures/app, each with one fault, and the copies of
# tests/external/app. tests/relock-fixtures.sh runs it after relocking; it
# needs no network.
#
#   stale-lock.json              made from another composer.lock
#   malformed/version-1.json     an older lock format version
#   malformed/no-packages.json   no `packages` field
#   malformed/entry-without-hash.json
#                                an entry without its hash
#   edited/missing-package.json  no entry named for psr/log
#   edited/extra-package.json    an entry named for a package that
#                                composer.lock does not have
#   edited/missing-entry.json    psr/log names a path with no entry
#   edited/tampered-hash.json    the monolog entry with the hash of psr/log,
#                                and the content hash left as it was
#
# Every one but tampered-hash.json gets the content hash of its edited
# content, so that its own fault is the one the checks see.
set -euo pipefail

tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$tests/fixtures"
lock="$fixtures/app/composer-purifier.lock.json"
fake="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

derive() {
  nix shell 'nixpkgs#jq' -c jq --indent 4 "$1" "$lock" > "$fixtures/$2"
}

rehash() {
  nix shell 'nixpkgs#php' -c php "$tests/rehash.php" "$fixtures/$1"
}

mkdir -p "$fixtures/malformed" "$fixtures/edited" "$tests/external/app"
derive ".composerLock = \"$fake\"" stale-lock.json
rehash stale-lock.json
derive '.version = 1' malformed/version-1.json
derive 'del(.packages)' malformed/no-packages.json
derive 'del(.artifacts[0].hash)' malformed/entry-without-hash.json
derive 'del(.packages["psr/log"])' edited/missing-package.json
rehash edited/missing-package.json
derive '.packages["fixture/not-locked"] = null' edited/extra-package.json
rehash edited/extra-package.json
derive '.artifacts |= map(select(.path | startswith("files/psr/log/") | not))' edited/missing-entry.json
rehash edited/missing-entry.json
derive '.artifacts[0].hash = .artifacts[1].hash' edited/tampered-hash.json

cp "$lock" "$fixtures/app/composer.lock" "$tests/external/app/"
