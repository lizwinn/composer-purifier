# SPDX-License-Identifier: MIT
#
# The `composer-purifier` command, for the Composer project in the current
# directory:
#
#   composer-purifier lock [--force] [--no-audit]
#       runs `composer audit --locked`, then writes
#       composer-purifier.lock.json next to composer.lock (src/lock.php)
#   composer-purifier install [<composer install arguments>]
#       builds the Composer cache of the lockfile, Composer on the PHP the
#       project requires, and the composer.lock of an offline install, with
#       nix-build (nix/lib/cli.nix); keeps them alive with GC roots under
#       .composer-purifier; and runs `composer install` offline
#   composer-purifier archive [<directory>]
#       builds the dist archive of the project in the Nix sandbox and copies
#       it into the directory, the current one by default
#
# `install` takes the cache from COMPOSER_PURIFIER_CACHE, Composer from
# COMPOSER_PURIFIER_COMPOSER and the composer.lock from
# COMPOSER_PURIFIER_OFFLINE_LOCK instead when all three are set, and then
# runs no nix-build. `lock` hashes version-control checkouts with the
# command that COMPOSER_PURIFIER_PREFETCH names, by default
# composer-purifier-prefetch (nix/lib/prefetch.nix).
{
  lib,
  path,
  stdenv,
  symlinkJoin,
  writeShellApplication,
  php,
}:
let
  composer = php.packages.composer;
  lockScript = ../../src/lock.php;
  nixLib = ../../nix/lib;

  nixArguments = ''
    --argstr nixpkgs ${path} \
    --argstr system ${stdenv.hostPlatform.system}'';

  prefetch = writeShellApplication {
    name = "composer-purifier-prefetch";
    text = ''
      # composer-purifier-prefetch <kind> <checkout as JSON>: prints the
      # hash of the checkout that the nixpkgs fetcher of the kind makes.
      kind="$1"
      checkout="$2"
      if output="$(nix-build ${nixLib}/prefetch.nix ${nixArguments} \
          --argstr kind "$kind" \
          --argstr checkout "$checkout" \
          --no-out-link 2>&1)"; then
        echo "composer-purifier-prefetch: the $kind fetcher accepted a fake hash" >&2
        exit 1
      fi
      hash="$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*$/\1/p')"
      if [ -z "$hash" ]; then
        printf '%s\n' "$output" >&2
        exit 1
      fi
      printf '%s\n' "$hash" | head -n 1
    '';
  };

  command = writeShellApplication {
    name = "composer-purifier";
    runtimeInputs = [
      php
      composer
    ];
    text = ''
      usage() {
        echo "usage: composer-purifier lock [--force] [--no-audit]" >&2
        echo "       composer-purifier install [<composer install arguments>]" >&2
        echo "       composer-purifier archive [<directory>]" >&2
        exit 2
      }

      [ $# -gt 0 ] || usage
      command="$1"
      shift

      case "$command" in
        lock)
          audit=1
          lockArguments=()
          for argument in "$@"; do
            case "$argument" in
              --no-audit) audit=0 ;;
              --force) lockArguments+=(--force) ;;
              *) usage ;;
            esac
          done
          # The install-time policy of Composer is off in the offline
          # installs, so the advisory and malware check runs here, online.
          if [ "$audit" = 1 ]; then
            composer audit --locked
          fi
          COMPOSER_PURIFIER_PREFETCH="''${COMPOSER_PURIFIER_PREFETCH:-${lib.getExe prefetch}}" \
            exec php ${lockScript} ${composer}/share/php/composer/vendor/autoload.php "''${lockArguments[@]}"
          ;;
        install)
          if [ ! -f composer-purifier.lock.json ]; then
            echo "composer-purifier: there is no composer-purifier.lock.json in $PWD. Run \`composer-purifier lock\` first." >&2
            exit 1
          fi
          mkdir -p .composer-purifier
          if [ -n "''${COMPOSER_PURIFIER_CACHE:-}" ] && [ -n "''${COMPOSER_PURIFIER_COMPOSER:-}" ] && [ -n "''${COMPOSER_PURIFIER_OFFLINE_LOCK:-}" ]; then
            cache="$COMPOSER_PURIFIER_CACHE"
            projectComposer="$COMPOSER_PURIFIER_COMPOSER"
            offlineLock="$COMPOSER_PURIFIER_OFFLINE_LOCK"
          else
            # `composer install` installs the require-dev packages unless it
            # is given --no-dev, and the PHP needs their extensions too.
            dev=1
            for argument in "$@"; do
              if [ "$argument" = --no-dev ]; then
                dev=0
              fi
            done
            for attribute in cache composer offlineLock; do
              nix-build ${nixLib}/cli.nix ${nixArguments} \
                --attr "$attribute" \
                --argstr projectDir "$PWD" \
                --argstr dev "$dev" \
                --out-link ".composer-purifier/$attribute" >/dev/null
            done
            cache="$(readlink .composer-purifier/cache)"
            projectComposer="$(readlink .composer-purifier/composer)"
            offlineLock="$(readlink .composer-purifier/offlineLock)"
          fi
          # Composer reads composer.json and the offline composer.lock from
          # .composer-purifier, and the project paths stay relative to the
          # current directory, since COMPOSER comes from the environment.
          cp composer.json .composer-purifier/composer.json
          cp --no-preserve=mode "$offlineLock" .composer-purifier/composer.lock
          export COMPOSER=.composer-purifier/composer.json
          export COMPOSER_CACHE_DIR="$cache"
          export COMPOSER_CACHE_FILES_DIR="$cache/files"
          export COMPOSER_CACHE_READ_ONLY=1
          export COMPOSER_DISABLE_NETWORK=1
          # The install-time policy fetches malware and advisory lists, which
          # an offline install cannot reach; `lock` runs the audit instead.
          export COMPOSER_POLICY=0
          exec "$projectComposer/bin/composer" install "$@"
          ;;
        archive)
          [ $# -le 1 ] || usage
          directory="''${1:-.}"
          archive="$(nix-build ${nixLib}/cli.nix ${nixArguments} \
            --attr archive \
            --argstr projectDir "$PWD" \
            --no-out-link)"
          for file in "$archive"/*; do
            cp --no-preserve=mode "$file" "$directory/"
            echo "$directory/$(basename "$file")"
          done
          ;;
        *)
          usage
          ;;
      esac
    '';
  };
in
symlinkJoin {
  name = "composer-purifier";
  paths = [
    command
    prefetch
  ];
  meta = {
    description = "Locks the downloads of a Composer project and installs it offline from them";
    license = lib.licenses.mit;
    mainProgram = "composer-purifier";
  };
}
