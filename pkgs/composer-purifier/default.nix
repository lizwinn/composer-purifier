# SPDX-License-Identifier: MIT
#
# The `composer-purifier` command, for the Composer project in the current
# directory:
#
#   composer-purifier lock [--force]
#       writes composer-purifier.lock.json next to composer.lock
#       (src/lock.php)
#   composer-purifier install [<composer install arguments>]
#       builds the Composer cache of the lockfile, and Composer on the PHP
#       the project requires, with nix-build (nix/lib/cli.nix); keeps both
#       alive with GC roots under .composer-purifier; and runs
#       `composer install` offline from the cache
#
# `install` takes the cache from COMPOSER_PURIFIER_CACHE and Composer from
# COMPOSER_PURIFIER_COMPOSER instead when both are set, and then runs no
# nix-build.
{
  lib,
  path,
  stdenv,
  writeShellApplication,
  php,
}:
let
  composer = php.packages.composer;
  lockScript = ../../src/lock.php;
  nixLib = ../../nix/lib;
in
writeShellApplication {
  name = "composer-purifier";
  runtimeInputs = [
    php
    composer
  ];
  text = ''
    usage() {
      echo "usage: composer-purifier lock [--force]" >&2
      echo "       composer-purifier install [<composer install arguments>]" >&2
      exit 2
    }

    [ $# -gt 0 ] || usage
    command="$1"
    shift

    case "$command" in
      lock)
        exec php ${lockScript} ${composer}/share/php/composer/vendor/autoload.php "$@"
        ;;
      install)
        if [ ! -f composer-purifier.lock.json ]; then
          echo "composer-purifier: there is no composer-purifier.lock.json in $PWD. Run \`composer-purifier lock\` first." >&2
          exit 1
        fi
        if [ -n "''${COMPOSER_PURIFIER_CACHE:-}" ] && [ -n "''${COMPOSER_PURIFIER_COMPOSER:-}" ]; then
          cache="$COMPOSER_PURIFIER_CACHE"
          projectComposer="$COMPOSER_PURIFIER_COMPOSER"
        else
          # `composer install` installs the require-dev packages unless it
          # is given --no-dev, and the PHP needs their extensions too.
          dev=1
          for argument in "$@"; do
            if [ "$argument" = --no-dev ]; then
              dev=0
            fi
          done
          mkdir -p .composer-purifier
          for attribute in cache composer; do
            nix-build ${nixLib}/cli.nix \
              --attr "$attribute" \
              --argstr nixpkgs ${path} \
              --argstr system ${stdenv.hostPlatform.system} \
              --argstr projectDir "$PWD" \
              --argstr dev "$dev" \
              --out-link ".composer-purifier/$attribute" >/dev/null
          done
          cache="$(readlink .composer-purifier/cache)"
          projectComposer="$(readlink .composer-purifier/composer)"
        fi
        export COMPOSER_CACHE_DIR="$cache"
        export COMPOSER_CACHE_FILES_DIR="$cache/files"
        export COMPOSER_CACHE_READ_ONLY=1
        export COMPOSER_DISABLE_NETWORK=1
        # The install-time policy fetches malware and advisory lists, which
        # an offline install cannot reach; see build-composer-project.nix.
        export COMPOSER_POLICY=0
        exec "$projectComposer/bin/composer" install "$@"
        ;;
      *)
        usage
        ;;
    esac
  '';
  meta = {
    description = "Locks the downloads of a Composer project and installs it offline from them";
    license = lib.licenses.mit;
    mainProgram = "composer-purifier";
  };
}
