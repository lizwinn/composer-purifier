# SPDX-License-Identifier: MIT
#
# The checks of composer-purifier. Each builds in the Nix sandbox. Only
# the fixed-output fetches of the fixtures' lockfiles reach the network.
#
# The checks of the purifier contract (CONTRACT.md of
# github:nix-purifiers/purifier):
#
#   conformance-stale      a lockfile made from a different composer.lock
#                          fails evaluation and `composer-purifier prefetch`,
#                          and a composer.lock changed after a prefetch stops
#                          the offline `composer install`; each names
#                          `composer-purifier lock`
#   conformance-tampered   a lockfile with an edited hash fails evaluation
#                          and `prefetch`, naming `composer-purifier lock
#                          --force`; the fetch of the edited entry checks
#                          the edited hash, and the CI workflow builds it
#                          (tests/tampered-hash.nix) to see Nix reject it
#   conformance-missing    lockfiles without an entry that composer.lock
#                          needs fail evaluation and `prefetch`, naming
#                          `composer-purifier lock --force`
#   conformance-malformed  lockfiles that are not valid fail evaluation and
#                          `prefetch`, naming `composer-purifier lock --force`
#   conformance-relock     relocking tests/fixtures/app, from the hashes it
#                          has, and tests/fixtures/vcs, with a stand-in for
#                          the checkout hash (tests/fake-hash-checkout.sh),
#                          reproduces each lockfile byte for byte
#   conformance-rebuild    two independent builds of tests/fixtures/app give
#                          the same package and the same release
#   conformance-offline    after `composer-purifier prefetch`, the everyday
#                          loop of tests/fixtures/app (`composer install`,
#                          the bin, `composer test`) and of
#                          tests/fixtures/sources runs with no network
#   conformance-external   tests/fixtures/app builds from a source that
#                          holds neither lockfile, with both given from
#                          tests/external/app
#
# The checks of composer-purifier itself:
#
#   fixture-app            the package of tests/fixtures/app runs its
#                          `hello` bin, which needs ext-bz2 (an extension
#                          the default nixpkgs PHP does not load) and
#                          monolog; its post-install-cmd script ran
#   fixture-sources        tests/fixtures/sources, whose packages come from
#                          a git source, a tar archive at a URL, a path
#                          repository inside the project and one outside
#                          it, builds and runs its `check` bin
#   fixture-vcs            tests/fixtures/vcs, whose packages come from
#                          git, hg, svn and fossil sources, builds with
#                          stand-ins for the fetchers that check the
#                          arguments the purifier library gives them
#   real-world-composer    composer/composer 2.10.3, a real project pinned
#                          in tests/dependencies, builds from the lockfile
#                          of tests/projects/composer and runs
#   tests                  the `tests` of tests/fixtures/app run its `test`
#                          script in the sandbox
#   unit                   the unit tests of src/functions.php
#                          (tests/unit/functions.php)
#   lock-reuse             after a change to composer.lock, `lock` keeps the
#                          hashes of the downloads the old lockfile names
#                          and downloads nothing
#   outputs                `packages`, `release`, `fetches` and `tests` of
#                          the fixtures are known at evaluation time and
#                          name the right outputs
#   release                the release of tests/fixtures/app is a zip of
#                          the project without its vendor directory
#   mirrors                the fetch of a file entry with mirrors
#                          (tests/fixtures/mirrors-lock.json) tries its URL
#                          and then its mirrors, with nixpkgs' fetchurl and
#                          with a `fetchurl` in its place
{
  pkgs,
  overlay,
  # lib.composer-purifier.buildComposerProject of this flake.
  buildComposerProject,
  # The `purifier` library namespace (lib.purifier of
  # github:nix-purifiers/purifier).
  purifier,
  # The source of composer/composer at its 2.10.3 release, an input of
  # tests/dependencies.
  composerSource,
}:
let
  purified = pkgs.extend overlay;
  inherit (purified) lib runCommand unzip;
  command = purified.composer-purifier.composer-purifier;

  build = arguments: buildComposerProject ({ pkgs = purified; } // arguments);

  app = build { src = ./fixtures/app; };
  appPackage = app.packages.composer-purifier-fixture-app;

  # Composer itself, with the lockfile of tests/projects/composer.
  realComposer = build {
    src = composerSource;
    lockFile = ./projects/composer/composer-purifier.lock.json;
  };

  sources = build {
    src = ./fixtures/sources;
    pathRepositories."../outer-package" = ./fixtures/outer-package;
  };

  # The stand-in checkout of a version-control package: a source tree
  # with the class that tests/fixtures/vcs/bin/check calls.
  standInCheckout =
    kind:
    let
      namespace = lib.toUpper (builtins.substring 0 1 kind) + builtins.substring 1 (-1) kind;
    in
    runCommand "fixture-${kind}-checkout" { } ''
      mkdir -p $out/src
      cat > $out/src/Hello.php <<'EOF'
      <?php
      namespace Fixture\${namespace};
      final class Hello
      {
          public static function text(): string
          {
              return 'hello from the ${kind} checkout';
          }
      }
      EOF
    '';

  # Stand-ins for the nixpkgs fetchers. Each checks the arguments that
  # the purifier library gives it for the entry of tests/fixtures/vcs.
  standInFetchers = {
    fetchgit =
      args:
      assert args.url == "https://example.invalid/fixture/git.git";
      assert args.rev == "0123456789abcdef0123456789abcdef01234567";
      assert args.fetchSubmodules == false;
      assert args.leaveDotGit == false;
      standInCheckout "git";
    fetchhg =
      args:
      assert args.url == "https://example.invalid/fixture/hg";
      assert args.rev == "89abcdef0123456789abcdef0123456789abcdef";
      assert args.fetchSubrepos;
      standInCheckout "hg";
    fetchsvn =
      args:
      assert args.url == "https://example.invalid/fixture/svn/trunk";
      assert args.rev == "7";
      assert args.ignoreExternals == false;
      assert args.ignoreKeywords == false;
      standInCheckout "svn";
    fetchfossil =
      args:
      assert args.url == "https://example.invalid/fixture/fossil";
      assert args.rev == "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
      assert lib.hasPrefix "sha256-" args.hash;
      standInCheckout "fossil";
  };

  vcs = build {
    src = ./fixtures/vcs;
    fetchers = standInFetchers;
  };

  # The app fixture from a source that holds neither of its lockfiles.
  external = build {
    src = builtins.path {
      path = ./fixtures/app;
      name = "fixture-app-without-lockfiles";
      filter =
        path: type:
        !(builtins.elem (baseNameOf path) [
          "composer-purifier.lock.json"
          "composer.lock"
        ]);
    };
    lockFile = ./external/app/composer-purifier.lock.json;
    composerLock = ./external/app/composer.lock;
  };

  # Whether the app fixture evaluates with a lockfile.
  accepted =
    lockFile:
    (builtins.tryEval
      (build {
        src = ./fixtures/app;
        inherit lockFile;
      }).packages.composer-purifier-fixture-app.drvPath
    ).success;

  # The monolog fetch of the app lockfile, and the same fetch of the
  # lockfile whose monolog hash was edited.
  monologPath = "files/monolog/monolog/13f7456348238a63d970854498776d96f53cdee8.zip";
  entryOf =
    lockFile:
    (builtins.head (
      builtins.filter (a: a.path == monologPath)
        (builtins.fromJSON (builtins.readFile lockFile)).artifacts
    ));
  originalFetch = purifier.fetchEntry { pkgs = purified; } (
    entryOf ./fixtures/app/composer-purifier.lock.json
  );
  tamperedEntry = entryOf ./fixtures/edited/tampered-hash.json;
  tamperedFetch = purifier.fetchEntry { pkgs = purified; } tamperedEntry;

  # What `composer-purifier prefetch` links for a fixture, in place of the
  # nix-build it runs outside the sandbox.
  prefetched = package: src: {
    COMPOSER_PURIFIER_CACHE = package.cache;
    COMPOSER_PURIFIER_COMPOSER = package.php.packages.composer;
    COMPOSER_PURIFIER_OFFLINE_LOCK = purified.callPackage ../nix/lib/offline-lock.nix {
      composerLock = builtins.fromJSON (builtins.readFile (src + "/composer.lock"));
      inherit (package.cache) lock fetch;
      rewritePaths = false;
    };
  };

  mirroredLockFile = ./fixtures/mirrors-lock.json;
  mirrored = builtins.head (builtins.fromJSON (builtins.readFile mirroredLockFile)).artifacts;
  mirroredUrls = [
    "https://example.invalid/dists/fixture-mirrored.zip"
    "https://mirror.example.invalid/dists/fixture-mirrored.zip"
  ];
  nixpkgsFetch = purifier.fetchEntry { pkgs = purified; } mirrored;
  overriddenFetch = purifier.fetchEntry {
    pkgs = purified;
    fetchurl = args: args;
  } mirrored;

  commandEnvironment = ''
    export HOME="$TMPDIR/home"
    export COMPOSER_HOME="$TMPDIR/composer-home"
    export COMPOSER_DISABLE_NETWORK=1
  '';

  # Copies tests/fixtures/app to ./project and changes into it.
  appProject = ''
    cp -r ${./fixtures/app} project
    chmod -R u+w project
    cd project
  '';

  # Runs `composer-purifier prefetch` on the project in the current
  # directory with the lockfile $1, and checks that it fails with a message
  # that contains $2.
  prefetchFails = ''
    prefetchFails() {
      if composer-purifier prefetch --lockfile "$1" 2> error; then
        echo "prefetch accepted $1" >&2
        exit 1
      fi
      cat error
      grep -qF "$2" error
    }
  '';
in
{
  conformance-stale =
    assert !(accepted ./fixtures/stale-lock.json);
    runCommand "conformance-stale-check"
      ({ nativeBuildInputs = [ command ]; } // prefetched app ./fixtures/app)
      ''
        ${commandEnvironment}
        ${appProject}
        ${prefetchFails}
        prefetchFails ${./fixtures/stale-lock.json} 'Run `composer-purifier lock`.'
        # A composer.lock that changes after a prefetch stops the offline
        # install, which names both commands.
        composer-purifier prefetch
        echo >> composer.lock
        if composer install 2> error; then
          echo "composer install ran on a stale lockfile" >&2
          exit 1
        fi
        cat error
        grep -qF 'Run `composer-purifier lock`.' error
        grep -qF 'composer-purifier prefetch' error
        touch $out
      '';

  conformance-tampered =
    assert !(accepted ./fixtures/edited/tampered-hash.json);
    assert tamperedFetch.outputHash == tamperedEntry.hash;
    assert tamperedFetch.outputHash != originalFetch.outputHash;
    runCommand "conformance-tampered-check" { nativeBuildInputs = [ command ]; } ''
      ${commandEnvironment}
      ${appProject}
      ${prefetchFails}
      prefetchFails ${./fixtures/edited/tampered-hash.json} 'was edited after `composer-purifier lock` wrote it'
      grep -qF 'Run `composer-purifier lock --force`' error
      touch $out
    '';

  conformance-missing =
    assert
      !(builtins.any accepted [
        ./fixtures/edited/missing-package.json
        ./fixtures/edited/missing-entry.json
        ./fixtures/edited/extra-package.json
      ]);
    runCommand "conformance-missing-check" { nativeBuildInputs = [ command ]; } ''
      ${commandEnvironment}
      ${appProject}
      ${prefetchFails}
      prefetchFails ${./fixtures/edited/missing-package.json} 'names no download for psr/log'
      prefetchFails ${./fixtures/edited/missing-entry.json} 'but has no entry at that path'
      prefetchFails ${./fixtures/edited/extra-package.json} 'which composer.lock does not have'
      grep -qF 'Run `composer-purifier lock --force`' error
      touch $out
    '';

  conformance-malformed =
    assert
      !(builtins.any accepted [
        ./fixtures/malformed/version-1.json
        ./fixtures/malformed/no-packages.json
        ./fixtures/malformed/entry-without-hash.json
      ]);
    runCommand "conformance-malformed-check" { nativeBuildInputs = [ command ]; } ''
      ${commandEnvironment}
      ${appProject}
      ${prefetchFails}
      prefetchFails ${./fixtures/malformed/version-1.json} 'has lock format version 1'
      prefetchFails ${./fixtures/malformed/no-packages.json} 'has no valid `packages` field'
      prefetchFails ${./fixtures/malformed/entry-without-hash.json} 'without a path or a hash'
      printf '{"version": 3,' > broken.json
      prefetchFails broken.json 'is not valid JSON'
      grep -qF 'Run `composer-purifier lock --force`' error
      touch $out
    '';

  conformance-relock =
    runCommand "conformance-relock-check"
      {
        nativeBuildInputs = [
          command
          purified.jq
        ];
      }
      ''
        ${commandEnvironment}
        ${appProject}
        # A lockfile that no longer matches composer.lock is written again;
        # its hashes come from the old one, without downloads.
        jq '.composerLock = ""' composer-purifier.lock.json > old.json
        mv old.json composer-purifier.lock.json
        composer-purifier lock --no-audit
        cmp ${./fixtures/app/composer-purifier.lock.json} composer-purifier.lock.json
        cd ..

        cp -r ${./fixtures/vcs} vcs
        chmod -R u+w vcs
        cd vcs
        rm composer-purifier.lock.json
        cp ${./fake-hash-checkout.sh} "$TMPDIR/fake-hash-checkout"
        chmod +x "$TMPDIR/fake-hash-checkout"
        patchShebangs "$TMPDIR/fake-hash-checkout"
        COMPOSER_PURIFIER_HASH_CHECKOUT="$TMPDIR/fake-hash-checkout" composer-purifier lock --no-audit
        cmp ${./fixtures/vcs/composer-purifier.lock.json} composer-purifier.lock.json
        touch $out
      '';

  conformance-rebuild =
    let
      # The same build as a second derivation, so that Nix builds it again
      # rather than reusing the first output.
      again =
        drv:
        drv.overrideAttrs (old: {
          composerPurifierRebuild = "again";
        });
    in
    # The wrappers in bin/ hold the store path of their own package, which
    # differs between the two builds, so each tree is compared with its own
    # store path replaced by the same placeholder. The CI workflow also
    # runs `nix build --rebuild` of the package, which compares one
    # derivation built twice.
    runCommand "conformance-rebuild-check" { } ''
      normalize() {
        local tree="$1" copy="$2"
        cp -r "$tree" "$copy"
        chmod -R u+w "$copy"
        find "$copy" -type f -exec sed -i "s|$tree|/nix/store/rebuilt|g" {} +
      }
      normalize ${appPackage} first
      normalize ${again appPackage} second
      diff -r first second
      cmp ${app.release} ${again app.release}
      touch $out
    '';

  conformance-offline =
    runCommand "conformance-offline-check"
      (
        {
          nativeBuildInputs = [
            command
            app.php
          ];
        }
        // prefetched app ./fixtures/app
      )
      ''
        ${commandEnvironment}
        ${appProject}
        composer-purifier prefetch
        composer install --no-interaction --no-progress
        test -f vendor/monolog/monolog/composer.json
        test "$(cat installed-by-script)" = yes
        test "$(php bin/hello)" = "hello from composer-purifier"
        composer test
        touch $out
      '';

  conformance-offline-sources =
    runCommand "conformance-offline-sources-check"
      (
        {
          nativeBuildInputs = [
            command
            sources.php
          ];
        }
        // prefetched sources ./fixtures/sources
      )
      ''
        ${commandEnvironment}
        mkdir work
        cp -r ${./fixtures/sources} work/sources
        cp -r ${./fixtures/outer-package} work/outer-package
        chmod -R u+w work
        cd work/sources
        composer-purifier prefetch
        composer install --no-interaction --no-progress
        php bin/check > output
        grep -q "outside the project" output
        test -f vendor/fixture/psr-clock/src/ClockInterface.php
        test -f vendor/fixture/psr-container/src/ContainerInterface.php
        touch $out
      '';

  conformance-external = runCommand "conformance-external-check" { } ''
    test "$(${lib.getExe external.packages.composer-purifier-fixture-app})" = "hello from composer-purifier"
    touch $out
  '';

  fixture-app = runCommand "fixture-app-check" { } ''
    output="$(${lib.getExe appPackage})"
    if [ "$output" != "hello from composer-purifier" ]; then
      echo "hello printed: $output" >&2
      exit 1
    fi
    test "$(cat ${appPackage}/share/php/composer-purifier-fixture-app/installed-by-script)" = yes
    test -f ${appPackage}/share/php/composer-purifier-fixture-app/vendor/monolog/monolog/composer.json
    touch $out
  '';

  fixture-sources = runCommand "fixture-sources-check" { } ''
    ${lib.getExe sources.packages.composer-purifier-fixture-sources} > output
    printf '%s\n' \
      "hello from the path package inside the project" \
      "hello from the path package outside the project" > expected
    diff expected output
    touch $out
  '';

  fixture-vcs = runCommand "fixture-vcs-check" { } ''
    ${lib.getExe vcs.packages.composer-purifier-fixture-vcs} > output
    printf '%s\n' \
      "hello from the git checkout" \
      "hello from the hg checkout" \
      "hello from the svn checkout" \
      "hello from the fossil checkout" > expected
    diff expected output
    touch $out
  '';

  # The integration check on a real project: Composer 2.10.3 builds from
  # its own composer.lock, its `composer` bin runs, and it validates its own
  # composer.json offline.
  real-world-composer =
    assert
      builtins.attrNames realComposer.packages == [
        "composer"
        "composer-composer"
      ];
    runCommand "real-world-composer-check" { } ''
      export HOME="$TMPDIR/home"
      export COMPOSER_HOME="$TMPDIR/composer-home"
      export COMPOSER_DISABLE_NETWORK=1
      ${lib.getExe realComposer.packages.composer} --version | grep -q 'Composer version 2.10.3'
      cd ${realComposer.packages.composer-composer}/share/php/composer-composer
      ${lib.getExe realComposer.packages.composer} validate --no-check-publish --no-check-lock
      touch $out
    '';

  inherit (app) tests;

  unit =
    runCommand "unit-check"
      {
        nativeBuildInputs = [ app.php ];
      }
      ''
        php ${./unit/functions.php} \
          ${app.php.packages.composer}/share/php/composer/vendor/autoload.php \
          ${../src/functions.php} \
          ${./fixtures}
        touch $out
      '';

  lock-reuse = runCommand "lock-reuse-check" { nativeBuildInputs = [ command ]; } ''
    ${commandEnvironment}
    ${appProject}
    echo >> composer.lock
    composer-purifier lock --no-audit
    # Only the hash of composer.lock and the content hash changed.
    diff <(grep -v -e '"composerLock"' -e '"contentHash"' ${./fixtures/app/composer-purifier.lock.json}) \
      <(grep -v -e '"composerLock"' -e '"contentHash"' composer-purifier.lock.json)
    ! diff -q ${./fixtures/app/composer-purifier.lock.json} composer-purifier.lock.json
    touch $out
  '';

  outputs =
    assert
      builtins.attrNames app.packages == [
        "composer-purifier-fixture-app"
        "hello"
      ];
    assert
      builtins.attrNames sources.packages == [
        "check"
        "composer-purifier-fixture-sources"
      ];
    assert
      app.fetches == (builtins.fromJSON (builtins.readFile ./fixtures/app/composer-purifier.lock.json))
      .artifacts;
    assert app.release.name == "composer-purifier-fixture-app-0.zip";
    # tests/fixtures/sources has no `test` script.
    assert !(builtins.tryEval sources.tests).success;
    runCommand "outputs-check" { } ''
      test "$(${lib.getExe app.packages.hello})" = "hello from composer-purifier"
      touch $out
    '';

  release = runCommand "release-check" { nativeBuildInputs = [ unzip ]; } ''
    unzip -l ${app.release} > listing
    grep -q ' composer.json$' listing
    grep -q ' src/Greeting.php$' listing
    ! grep -q ' vendor/' listing
    touch $out
  '';

  mirrors =
    assert nixpkgsFetch.urls == mirroredUrls;
    assert overriddenFetch.urls == mirroredUrls;
    runCommand "mirrors-check" { } "touch $out";
}
