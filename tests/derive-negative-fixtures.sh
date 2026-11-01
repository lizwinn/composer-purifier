#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Writes the faulty files of the negative tests from the files of
# tests/fixtures/app, each with one fault, and the copies of
# tests/external/app. tests/relock-fixtures.sh runs it after relocking; it
# needs no network.
#
#   stale/composer.lock           the composer.lock of app with monolog at
#                                 another dist URL, as after an update that
#                                 the lockfile has not seen
#   malformed/version-3.json      an older lock format version
#   malformed/no-dists.json       no `dists` field
#   malformed/dist-hash-not-text.json
#                                 a dist hash that is a number
#   edited/missing-dist.json      no hash for the dist of psr/log
#   edited/tampered-hash.json     the monolog hash replaced by the psr/log
#                                 hash, and the content hash left as it was
#
# Every lockfile but tampered-hash.json gets the content hash of its edited
# content, so that its own fault is the one the checks see.
set -euo pipefail

tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$tests/fixtures"
lock="$fixtures/app/composer-purifier.lock.json"

jq() {
  nix shell 'nixpkgs#jq' -c jq --indent 4 "$@"
}

derive() {
  jq "$1" "$lock" > "$fixtures/$2"
}

rehash() {
  nix shell 'nixpkgs#php' -c php "$tests/rehash.php" "$fixtures/$1"
}

mkdir -p "$fixtures/stale" "$fixtures/malformed" "$fixtures/edited" "$tests/external/app"
jq '(.packages[] | select(.name == "monolog/monolog") | .dist.url) |= . + "?stale"' \
  "$fixtures/app/composer.lock" > "$fixtures/stale/composer.lock"
derive '.version = 3' malformed/version-3.json
rehash malformed/version-3.json
derive 'del(.dists)' malformed/no-dists.json
derive '.dists |= with_entries(.value = 1)' malformed/dist-hash-not-text.json
derive '.dists |= with_entries(select(.key | contains("php-fig/log") | not))' edited/missing-dist.json
rehash edited/missing-dist.json
derive '.dists |= with_entries(if (.key | contains("Seldaek/monolog")) then .value = "sha256-Ho3PLfkz/DRAspFGxcpOk+zlHFx6msllPZJuyXHJCJI=" else . end)' edited/tampered-hash.json

cp "$lock" "$fixtures/app/composer.lock" "$tests/external/app/"
