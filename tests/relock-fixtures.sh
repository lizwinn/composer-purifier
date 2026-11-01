#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Writes the lockfiles of the test fixtures again: composer.lock with
# `composer update`, then composer-purifier.lock.json with the
# composer-purifier of this checkout. Run it from the repository root after
# changing a fixture's composer.json.
#
# app and sources lock with the network. vcs names unreachable
# repositories, so it locks offline, with tests/fake-prefetch.sh in place
# of the prefetch command. tests/fixtures/outer-package is a path package
# of sources, and has no lockfile of its own.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
composerPurifier="$(nix build --no-link --print-out-paths "path:$root#composer-purifier")/bin/composer-purifier"
home="$(mktemp -d)"
trap 'rm -rf "$home"' EXIT

composer() {
  COMPOSER_HOME="$home" nix shell 'nixpkgs#php.packages.composer' -c composer "$@"
}

for fixture in app sources; do
  echo "Relocking $fixture" >&2
  (
    cd "$root/tests/fixtures/$fixture"
    # The fixtures may require extensions that the default PHP does not
    # load; the Nix build supplies them.
    composer update --no-install --no-interaction --ignore-platform-reqs
    COMPOSER_HOME="$home" "$composerPurifier" lock --force
  )
done

echo "Relocking vcs" >&2
(
  cd "$root/tests/fixtures/vcs"
  COMPOSER_DISABLE_NETWORK=1 composer update --no-install --no-interaction --no-audit
  COMPOSER_HOME="$home" COMPOSER_DISABLE_NETWORK=1 \
    COMPOSER_PURIFIER_PREFETCH="$root/tests/fake-prefetch.sh" \
    "$composerPurifier" lock --force --no-audit
)

# The stale lockfile of the stale-lock check is the app lockfile with
# another composer.lock hash.
sed 's/"composerLock": "sha256-[^"]*"/"composerLock": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="/' \
  "$root/tests/fixtures/app/composer-purifier.lock.json" > "$root/tests/fixtures/stale-lock.json"
