# SPDX-License-Identifier: MIT
#
# The commands of the purifier contract, for the Composer project in the
# current directory:
#
#   composer-purifier lock [--force] [--no-audit]
#       runs `composer audit --locked`, then writes
#       composer-purifier.lock.json next to composer.lock (src/lock.php)
#   composer-purifier prefetch
#       builds, with nix-build (nix/lib/cli.nix), the Composer cache of the
#       lockfile, Composer on the PHP the project requires with its
#       require-dev packages, and the composer.lock of an offline install;
#       keeps them alive with GC roots under .composer-purifier
#   composer-purifier publish <directory>
#       builds the release of the project, its dist archive, in the Nix
#       sandbox and copies it into the directory, such as the directory of
#       a Composer `artifact` repository
#
# and `composer`, the build tool of the everyday loop. After a prefetch,
# `composer install` reads the prefetched files and runs offline; every
# other subcommand, and `install` before a prefetch, is plain Composer.
#
# `prefetch` links the cache, Composer and the composer.lock of
# COMPOSER_PURIFIER_CACHE, COMPOSER_PURIFIER_COMPOSER and
# COMPOSER_PURIFIER_OFFLINE_LOCK instead when all three are set, and then
# runs no nix-build. `lock` hashes version-control checkouts with the
# command that COMPOSER_PURIFIER_HASH_CHECKOUT names, by default
# composer-purifier-hash-checkout (nix/lib/hash-checkout.nix).
{
  lib,
  path,
  stdenv,
  coreutils,
  symlinkJoin,
  writeShellApplication,
  php,
  # The source directory of the purifier library, whose fetches the
  # nix-build calls of the commands import. The default package overlay
  # gives it from the `purifier` input of this flake.
  purifierSource ? throw "composer-purifier: the composer-purifier package needs the source of the purifier library as purifierSource.",
}:
let
  defaultComposer = php.packages.composer;
  # src/lock.php and src/check.php require src/functions.php beside them.
  scripts = ../../src;
  nixLib = ../../nix/lib;

  nixArguments = ''
    --argstr nixpkgs ${path} \
    --argstr purifier ${purifierSource} \
    --argstr system ${stdenv.hostPlatform.system}'';

  hashCheckout = writeShellApplication {
    name = "composer-purifier-hash-checkout";
    text = ''
      # composer-purifier-hash-checkout <kind> <checkout as JSON>: prints
      # the hash of the checkout that the purifier library fetches.
      kind="$1"
      checkout="$2"
      if output="$(nix-build ${nixLib}/hash-checkout.nix ${nixArguments} \
          --argstr kind "$kind" \
          --argstr checkout "$checkout" \
          --no-out-link 2>&1)"; then
        echo "composer-purifier-hash-checkout: the $kind fetch accepted a fake hash" >&2
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

  # The contentHash of the lockfile at "$lockFile".
  lockHash = ''php ${scripts}/lock-hash.php "$lockFile"'';

  purifierCommand = writeShellApplication {
    name = "composer-purifier";
    runtimeInputs = [
      php
      defaultComposer
      coreutils
    ];
    text = ''
      usage() {
        echo "usage: composer-purifier lock [--lockfile <path>] [--force] [--no-audit]" >&2
        echo "       composer-purifier prefetch [--lockfile <path>]" >&2
        echo "       composer-purifier publish [--lockfile <path>] <directory>" >&2
        exit 2
      }

      [ $# -gt 0 ] || usage
      command="$1"
      shift

      # --lockfile names a composer-purifier.lock.json outside the project,
      # for a project whose source does not hold it.
      lockFile=composer-purifier.lock.json
      audit=1
      force=0
      operands=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --lockfile)
            [ $# -ge 2 ] || usage
            lockFile="$2"
            shift 2
            ;;
          --no-audit) audit=0; shift ;;
          --force) force=1; shift ;;
          *) operands+=("$1"); shift ;;
        esac
      done
      lockFile="$(realpath -m "$lockFile")"

      case "$command" in
        lock)
          [ ''${#operands[@]} -eq 0 ] || usage
          lockArguments=(--lockfile "$lockFile")
          if [ "$force" = 1 ]; then
            lockArguments+=(--force)
          fi
          # The install-time policy of Composer is off in the offline
          # installs, so the advisory and malware check runs here, online.
          if [ "$audit" = 1 ]; then
            composer audit --locked
          fi
          COMPOSER_PURIFIER_HASH_CHECKOUT="''${COMPOSER_PURIFIER_HASH_CHECKOUT:-${lib.getExe hashCheckout}}" \
            exec php ${scripts}/lock.php ${defaultComposer}/share/php/composer/vendor/autoload.php "''${lockArguments[@]}"
          ;;
        prefetch)
          [ ''${#operands[@]} -eq 0 ] || usage
          # Stops with the command to run when the lockfile is missing,
          # malformed, stale or edited (src/check.php).
          php ${scripts}/check.php "$lockFile"
          mkdir -p .composer-purifier
          if [ -n "''${COMPOSER_PURIFIER_CACHE:-}" ] && [ -n "''${COMPOSER_PURIFIER_COMPOSER:-}" ] && [ -n "''${COMPOSER_PURIFIER_OFFLINE_LOCK:-}" ]; then
            ln -sfn "$COMPOSER_PURIFIER_CACHE" .composer-purifier/cache
            ln -sfn "$COMPOSER_PURIFIER_COMPOSER" .composer-purifier/composer
            ln -sfn "$COMPOSER_PURIFIER_OFFLINE_LOCK" .composer-purifier/offlineLock
          else
            for attribute in cache composer offlineLock; do
              nix-build ${nixLib}/cli.nix ${nixArguments} \
                --attr "$attribute" \
                --argstr projectDir "$PWD" \
                --argstr lockFile "$lockFile" \
                --out-link ".composer-purifier/$attribute" >/dev/null
            done
          fi
          # The offline `composer install` checks the same lockfile, and
          # that it has not changed since this prefetch.
          printf '%s\n' "$lockFile" > .composer-purifier/lockfile
          ${lockHash} > .composer-purifier/lock-hash
          echo "composer-purifier: prefetched the downloads of $lockFile into .composer-purifier; \`composer install\` now runs offline." >&2
          ;;
        publish)
          [ ''${#operands[@]} -eq 1 ] || usage
          release="$(nix-build ${nixLib}/cli.nix ${nixArguments} \
            --attr release \
            --argstr projectDir "$PWD" \
            --argstr lockFile "$lockFile" \
            --no-out-link)"
          target="''${operands[0]}/$(basename "$release" | cut -d- -f2-)"
          cp --no-preserve=mode "$release" "$target"
          echo "$target"
          ;;
        *)
          usage
          ;;
      esac
    '';
  };

  composerCommand = writeShellApplication {
    name = "composer";
    runtimeInputs = [
      php
      coreutils
    ];
    text = ''
      # After `composer-purifier prefetch`, `composer install` runs offline
      # from the prefetched files, with Composer on the PHP the project
      # requires. Every other subcommand, and `install` before a prefetch,
      # is plain Composer.
      projectComposer=${defaultComposer}
      if [ -e .composer-purifier/composer ]; then
        projectComposer="$(readlink -f .composer-purifier/composer)"
      fi
      if [ "''${1:-}" != install ] || [ ! -e .composer-purifier/cache ]; then
        exec "$projectComposer/bin/composer" "$@"
      fi

      lockFile="$(cat .composer-purifier/lockfile)"
      if ! php ${scripts}/check.php "$lockFile"; then
        echo "composer-purifier: then run \`composer-purifier prefetch\`, and \`composer install\` again." >&2
        exit 1
      fi
      if [ "$(${lockHash})" != "$(cat .composer-purifier/lock-hash)" ]; then
        echo "composer-purifier: composer-purifier.lock.json changed after the last prefetch. Run \`composer-purifier prefetch\`." >&2
        exit 1
      fi
      cache="$(readlink -f .composer-purifier/cache)"
      # Composer reads composer.json and the offline composer.lock from
      # .composer-purifier, and the project paths stay relative to the
      # current directory, since COMPOSER comes from the environment.
      cp composer.json .composer-purifier/composer.json
      cp --no-preserve=mode .composer-purifier/offlineLock .composer-purifier/composer.lock
      export COMPOSER=.composer-purifier/composer.json
      export COMPOSER_CACHE_DIR="$cache"
      export COMPOSER_CACHE_FILES_DIR="$cache/files"
      export COMPOSER_CACHE_READ_ONLY=1
      export COMPOSER_DISABLE_NETWORK=1
      # The install-time policy fetches malware and advisory lists, which
      # an offline install cannot reach; `lock` runs the audit instead.
      export COMPOSER_POLICY=0
      exec "$projectComposer/bin/composer" "$@"
    '';
  };
in
symlinkJoin {
  name = "composer-purifier";
  paths = [
    purifierCommand
    composerCommand
    hashCheckout
  ];
  meta = {
    description = "Locks the downloads of a Composer project, prefetches them, and installs it offline from them";
    license = lib.licenses.mit;
    mainProgram = "composer-purifier";
  };
}
