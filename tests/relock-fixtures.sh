#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Writes the lockfiles of the test fixtures again, with the network:
# composer.lock with `composer update`, then composer-purifier.lock.json
# with the composer-purifier of this checkout. Run it from the repository
# root after changing a fixture's composer.json.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
composerPurifier="$(nix build --no-link --print-out-paths "path:$root#composer-purifier")/bin/composer-purifier"
home="$(mktemp -d)"
trap 'rm -rf "$home"' EXIT

for fixture in "$root"/tests/fixtures/*/; do
  echo "Relocking $fixture" >&2
  (
    cd "$fixture"
    # The fixtures may require extensions that the default PHP does not
    # load; the Nix build supplies them.
    COMPOSER_HOME="$home" nix shell 'nixpkgs#php.packages.composer' -c \
      composer update --no-install --no-interaction --ignore-platform-reqs
    COMPOSER_HOME="$home" "$composerPurifier" lock --force
  )
done
