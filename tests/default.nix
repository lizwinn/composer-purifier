# SPDX-License-Identifier: MIT
#
# The checks of composer-purifier. Each builds in the Nix sandbox, with no
# network: the fixtures' lockfiles name every file their builds download.
#
#   fixture-app        builds tests/fixtures/app with buildComposerProject
#                      and runs its `hello` bin, which needs ext-bz2 (an
#                      extension the default nixpkgs PHP does not load) and
#                      monolog from the lockfile; checks that the
#                      post-install-cmd script of composer.json ran
#   stale-lock         a lockfile made from another composer.lock fails the
#                      build at evaluation
#   cli-install        `composer-purifier install` installs the fixture
#                      offline from the Composer cache of its lockfile,
#                      with Composer on the PHP the fixture requires, and
#                      runs its post-install-cmd script
{
  pkgs,
  overlay,
}:
let
  purified = pkgs.extend overlay;
  inherit (purified) lib buildComposerProject runCommand;

  app = buildComposerProject { src = ./fixtures/app; };

  # The fixture with a composer.lock that differs from the one its
  # lockfile was made from.
  staleSrc = runCommand "fixture-app-stale" { } ''
    cp -r ${./fixtures/app} $out
    chmod -R u+w $out
    echo >> $out/composer.lock
  '';
  staleBuild = builtins.tryEval (buildComposerProject { src = staleSrc; }).drvPath;
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

  stale-lock =
    assert !staleBuild.success;
    runCommand "stale-lock-check" { } "touch $out";

  cli-install =
    runCommand "cli-install-check"
      {
        nativeBuildInputs = [ purified.composer-purifier.composer-purifier ];
        COMPOSER_PURIFIER_CACHE = app.cache;
        COMPOSER_PURIFIER_COMPOSER = app.php.packages.composer;
      }
      ''
        export HOME="$TMPDIR/home"
        export COMPOSER_HOME="$TMPDIR/composer-home"
        cp -r ${./fixtures/app} project
        chmod -R u+w project
        cd project
        composer-purifier install --no-interaction --no-progress
        test -f vendor/monolog/monolog/composer.json
        test -f vendor/psr/log/composer.json
        test "$(cat installed-by-script)" = yes
        touch $out
      '';
}
