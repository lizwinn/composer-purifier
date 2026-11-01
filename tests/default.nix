# SPDX-License-Identifier: MIT
#
# The checks of composer-purifier. Each builds in the Nix sandbox. Only
# the fixed-output fetches of the fixtures' lockfiles reach the network.
#
#   fixture-app        builds tests/fixtures/app with buildComposerProject
#                      and runs its `hello` bin, which needs ext-bz2 (an
#                      extension the default nixpkgs PHP does not load) and
#                      monolog from the lockfile; checks that the
#                      post-install-cmd script of composer.json ran
#   fixture-sources    builds tests/fixtures/sources, whose packages come
#                      from a git source, a tar archive at a URL, a path
#                      repository inside the project and one outside it,
#                      and runs its `check` bin
#   real-world-composer  builds composer/composer 2.10.3, a real project
#                      pinned in tests/dependencies, from the lockfile of
#                      tests/projects/composer, and runs it
#   fixture-vcs        builds tests/fixtures/vcs, whose packages come from
#                      git, hg, svn and fossil sources, with stand-ins for
#                      the nixpkgs fetchers that check the arguments they
#                      get, and runs its `check` bin
#   unit               the unit tests of src/functions.php
#                      (tests/unit/functions.php)
#   rejected-lockfiles each faulty lockfile of tests/derive-negative-fixtures.sh
#                      fails the build of the app fixture at evaluation:
#                      one made from a different composer.lock, malformed
#                      ones, and ones edited to miss or add an entry
#   tampered-hash      the fetch of an entry whose hash was edited is a
#                      fixed-output derivation with that hash, which Nix
#                      rejects when the download does not match; the CI
#                      workflow builds tests/tampered-hash.nix to see the
#                      rejection
#   cli-rejects-stale  `composer-purifier install` stops on a lockfile made
#                      from a different composer.lock, and says to run
#                      `composer-purifier lock`
#   lock-vcs           `composer-purifier lock` writes the lockfile of
#                      tests/fixtures/vcs again, offline, with a stand-in
#                      for the prefetch command (tests/fake-prefetch.sh),
#                      and it matches the committed one byte for byte
#   relock-identical   relocking tests/fixtures/app reproduces its lockfile
#                      byte for byte, from the hashes it already has
#   lock-reuse         after a change to composer.lock, `composer-purifier
#                      lock` keeps the hashes of the downloads the old
#                      lockfile names and downloads nothing
#   cli-install        `composer-purifier install` installs tests/fixtures/app
#                      offline from the Composer cache of its lockfile, with
#                      Composer on the PHP the fixture requires, and runs
#                      its post-install-cmd script
#   cli-install-sources  the same for tests/fixtures/sources, whose path
#                      repository outside the project stays on the file
#                      system
#   outputs            the `bins` and `artifacts` of the fixtures, known from
#                      composer.json at evaluation time, name the right
#                      outputs, and they build and run
#   archive            the dist archive of tests/fixtures/app is a zip of
#                      the project without its vendor directory
#   mirrors            the fetch of a file entry with mirrors
#                      (tests/fixtures/mirrors-lock.json) tries its URL and
#                      then its mirrors, with the built-in fetcher and with
#                      a `fetchurl` in its place
{
  pkgs,
  overlay,
  # The source of composer/composer at its 2.10.3 release, an input of
  # tests/dependencies.
  composerSource,
}:
let
  purified = pkgs.extend overlay;
  inherit (purified)
    lib
    buildComposerProject
    runCommand
    unzip
    ;
  command = purified.composer-purifier.composer-purifier;

  app = buildComposerProject { src = ./fixtures/app; };

  # Composer itself, with the lockfile of tests/projects/composer.
  realComposer = buildComposerProject {
    src = composerSource;
    lockFile = ./projects/composer/composer-purifier.lock.json;
  };

  sources = buildComposerProject {
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
  # fetch.nix gives it for the entry of tests/fixtures/vcs.
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
      assert lib.hasPrefix "sha256-" args.outputHash;
      standInCheckout "fossil";
  };

  vcs = buildComposerProject {
    src = ./fixtures/vcs;
    vcsFetchers = standInFetchers;
  };

  # The faulty lockfiles of tests/derive-negative-fixtures.sh, each of
  # which the build of the app fixture has to reject at evaluation.
  rejectedLockFiles = [
    ./fixtures/stale-lock.json
    ./fixtures/malformed/version-1.json
    ./fixtures/malformed/no-packages.json
    ./fixtures/malformed/entry-without-hash.json
    ./fixtures/edited/missing-package.json
    ./fixtures/edited/extra-package.json
    ./fixtures/edited/missing-entry.json
  ];
  accepted =
    lockFile:
    (builtins.tryEval
      (buildComposerProject {
        src = ./fixtures/app;
        inherit lockFile;
      }).drvPath
    ).success;

  # The monolog fetch of the app lockfile, and the same fetch of the
  # lockfile whose monolog hash was edited.
  monologPath = "files/monolog/monolog/13f7456348238a63d970854498776d96f53cdee8.zip";
  fetchOf =
    lockFile:
    let
      lock = import ../nix/lib/lock.nix { inherit lockFile; };
    in
    import ../nix/lib/fetch.nix { inherit lock; } lock.artifactsByPath.${monologPath};
  originalFetch = fetchOf ./fixtures/app/composer-purifier.lock.json;
  tamperedFetch = fetchOf ./fixtures/edited/tampered-hash.json;
  tamperedLock = builtins.fromJSON (builtins.readFile ./fixtures/edited/tampered-hash.json);

  # The composer.lock that `composer-purifier install` reads for a fixture,
  # with its path repositories as they are on the file system.
  installLock =
    package: src:
    purified.callPackage ../nix/lib/offline-lock.nix {
      composerLock = builtins.fromJSON (builtins.readFile (src + "/composer.lock"));
      inherit (package.cache) lock fetch;
      rewritePaths = false;
    };

  mirroredLock = import ../nix/lib/lock.nix { lockFile = ./fixtures/mirrors-lock.json; };
  mirrored = builtins.head mirroredLock.artifacts;
  mirroredUrls = [
    "https://example.invalid/dists/fixture-mirrored.zip"
    "https://mirror.example.invalid/dists/fixture-mirrored.zip"
  ];
  builtinFetch = import ../nix/lib/fetch.nix { lock = mirroredLock; } mirrored;
  overriddenFetch = import ../nix/lib/fetch.nix {
    lock = mirroredLock;
    fetchurl = args: args;
  } mirrored;

  commandEnvironment = ''
    export HOME="$TMPDIR/home"
    export COMPOSER_HOME="$TMPDIR/composer-home"
    export COMPOSER_DISABLE_NETWORK=1
  '';
in
{
  fixture-app = runCommand "fixture-app-check" { } ''
    output="$(${lib.getExe app})"
    if [ "$output" != "hello from composer-purifier" ]; then
      echo "hello printed: $output" >&2
      exit 1
    fi
    test "$(cat ${app}/share/php/composer-purifier-fixture-app/installed-by-script)" = yes
    test -f ${app}/share/php/composer-purifier-fixture-app/vendor/monolog/monolog/composer.json
    touch $out
  '';

  # The integration check on a real project: Composer 2.10.3 builds from
  # its own composer.lock, its `composer` bin runs, and it validates its own
  # composer.json offline.
  real-world-composer =
    assert builtins.attrNames realComposer.bins == [ "composer" ];
    runCommand "real-world-composer-check" { } ''
      export HOME="$TMPDIR/home"
      export COMPOSER_HOME="$TMPDIR/composer-home"
      export COMPOSER_DISABLE_NETWORK=1
      ${lib.getExe realComposer.bins.composer} --version | grep -q 'Composer version 2.10.3'
      cd ${realComposer}/share/php/composer-composer
      ${lib.getExe realComposer.bins.composer} validate --no-check-publish --no-check-lock
      touch $out
    '';

  fixture-sources = runCommand "fixture-sources-check" { } ''
    ${lib.getExe sources} > output
    printf '%s\n' \
      "hello from the path package inside the project" \
      "hello from the path package outside the project" > expected
    diff expected output
    touch $out
  '';

  fixture-vcs = runCommand "fixture-vcs-check" { } ''
    ${lib.getExe vcs} > output
    printf '%s\n' \
      "hello from the git checkout" \
      "hello from the hg checkout" \
      "hello from the svn checkout" \
      "hello from the fossil checkout" > expected
    diff expected output
    touch $out
  '';

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

  rejected-lockfiles =
    assert accepted ./fixtures/app/composer-purifier.lock.json;
    assert builtins.all (lockFile: !(accepted lockFile)) rejectedLockFiles;
    runCommand "rejected-lockfiles-check" { } "touch $out";

  tampered-hash =
    assert tamperedFetch.outputHash == (builtins.head tamperedLock.artifacts).hash;
    assert tamperedFetch.outputHash != originalFetch.outputHash;
    assert tamperedFetch.outputHashMode == "flat";
    runCommand "tampered-hash-check" { } "touch $out";

  cli-rejects-stale =
    runCommand "cli-rejects-stale-check"
      {
        nativeBuildInputs = [ command ];
      }
      ''
        ${commandEnvironment}
        cp -r ${./fixtures/app} project
        chmod -R u+w project
        cd project
        echo >> composer.lock
        if composer-purifier install 2> error; then
          echo "install accepted a stale lockfile" >&2
          exit 1
        fi
        cat error
        grep -q 'composer.lock changed after composer-purifier.lock.json was written. Run `composer-purifier lock`.' error
        touch $out
      '';

  relock-identical =
    runCommand "relock-identical-check"
      {
        nativeBuildInputs = [
          command
          purified.jq
        ];
      }
      ''
        ${commandEnvironment}
        cp -r ${./fixtures/app} project
        chmod -R u+w project
        cd project
        # A lockfile that no longer matches composer.lock is written again;
        # its hashes come from the old one, without downloads.
        jq '.composerLock = ""' composer-purifier.lock.json > old.json
        mv old.json composer-purifier.lock.json
        composer-purifier lock --no-audit
        cmp ${./fixtures/app/composer-purifier.lock.json} composer-purifier.lock.json
        touch $out
      '';

  lock-vcs = runCommand "lock-vcs-check" { nativeBuildInputs = [ command ]; } ''
    ${commandEnvironment}
    cp -r ${./fixtures/vcs} project
    chmod -R u+w project
    cd project
    rm composer-purifier.lock.json
    cp ${./fake-prefetch.sh} "$TMPDIR/fake-prefetch"
    chmod +x "$TMPDIR/fake-prefetch"
    patchShebangs "$TMPDIR/fake-prefetch"
    COMPOSER_PURIFIER_PREFETCH="$TMPDIR/fake-prefetch" composer-purifier lock --no-audit
    diff ${./fixtures/vcs/composer-purifier.lock.json} composer-purifier.lock.json
    touch $out
  '';

  lock-reuse = runCommand "lock-reuse-check" { nativeBuildInputs = [ command ]; } ''
    ${commandEnvironment}
    cp -r ${./fixtures/app} project
    chmod -R u+w project
    cd project
    echo >> composer.lock
    composer-purifier lock --no-audit
    # Only the hash of composer.lock changed.
    diff <(grep -v '"composerLock"' ${./fixtures/app/composer-purifier.lock.json}) \
      <(grep -v '"composerLock"' composer-purifier.lock.json)
    ! diff -q ${./fixtures/app/composer-purifier.lock.json} composer-purifier.lock.json
    touch $out
  '';

  cli-install =
    runCommand "cli-install-check"
      {
        nativeBuildInputs = [ command ];
        COMPOSER_PURIFIER_CACHE = app.cache;
        COMPOSER_PURIFIER_COMPOSER = app.php.packages.composer;
        COMPOSER_PURIFIER_OFFLINE_LOCK = installLock app ./fixtures/app;
      }
      ''
        ${commandEnvironment}
        cp -r ${./fixtures/app} project
        chmod -R u+w project
        cd project
        composer-purifier install --no-interaction --no-progress
        test -f vendor/monolog/monolog/composer.json
        test -f vendor/psr/log/composer.json
        test "$(cat installed-by-script)" = yes
        touch $out
      '';

  cli-install-sources =
    runCommand "cli-install-sources-check"
      {
        nativeBuildInputs = [ command ];
        COMPOSER_PURIFIER_CACHE = sources.cache;
        COMPOSER_PURIFIER_COMPOSER = sources.php.packages.composer;
        COMPOSER_PURIFIER_OFFLINE_LOCK = installLock sources ./fixtures/sources;
      }
      ''
        ${commandEnvironment}
        mkdir work
        cp -r ${./fixtures/sources} work/sources
        cp -r ${./fixtures/outer-package} work/outer-package
        chmod -R u+w work
        cd work/sources
        composer-purifier install --no-interaction --no-progress
        ${lib.getExe sources.php} bin/check > output
        grep -q "outside the project" output
        test -f vendor/fixture/psr-clock/src/ClockInterface.php
        test -f vendor/fixture/psr-container/src/ContainerInterface.php
        touch $out
      '';

  mirrors =
    assert builtinFetch.drvAttrs.urls == mirroredUrls;
    assert overriddenFetch.urls == mirroredUrls;
    runCommand "mirrors-check" { } "touch $out";

  # The outputs of the app fixture are known from composer.json at
  # evaluation time: one bin and one archive.
  outputs =
    assert builtins.attrNames app.bins == [ "hello" ];
    assert builtins.attrNames app.artifacts == [ "composer-purifier-fixture-app-0.zip" ];
    assert builtins.attrNames sources.bins == [ "check" ];
    runCommand "outputs-check" { } ''
      test "$(${lib.getExe app.bins.hello})" = "hello from composer-purifier"
      test -f ${app.artifacts."composer-purifier-fixture-app-0.zip"}
      touch $out
    '';

  archive = runCommand "archive-check" { nativeBuildInputs = [ unzip ]; } ''
    zip=${app.artifacts."composer-purifier-fixture-app-0.zip"}
    unzip -l "$zip" > listing
    grep -q ' composer.json$' listing
    grep -q ' src/Greeting.php$' listing
    ! grep -q ' vendor/' listing
    touch $out
  '';
}
