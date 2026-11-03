# SPDX-License-Identifier: MIT
{
  lib,
  purifier,
  runCommand,
  python3,
  composer,
  php,
  src,
  installed,
  composerLock,
  origins,
  dependencies,
  platformRequirements,
  repositoryTools ? ../../tools,
}:
let
  selected = purifier.projectInputs {
    inherit dependencies;
    formats = [ "composer" ];
  };
  projector = "${repositoryTools}/composer_repository.py";
  toolchain = runCommand "composer-projector-toolchain" {
    inherit projector python3;
    composerSource = composer.src;
    composerVersion = composer.version;
    phpVersion = php.version;
  } "touch $out";
  projection =
    runCommand "composer-artifact-repository"
      {
        outputs = [
          "out"
          "metadata"
        ];
        request = builtins.toJSON {
          inherit
            src
            installed
            composerLock
            origins
            ;
          php = lib.getExe php;
          autoload = "${composer}/share/php/composer/vendor/autoload.php";
          sourceIdentity = (purifier.inputIdentity src).hash;
          projectorIdentity = (purifier.inputIdentity toolchain).hash;
          dependencies = map (input: {
            repository = toString input.repository;
            catalog = input.repository.catalog;
          }) selected;
        };
        passAsFile = [ "request" ];
        passthru.catalog = "${projection.metadata}/catalog.json";
        passthru.platformRequirements = platformRequirements;
      }
      ''
        ${lib.getExe python3} ${projector} "$requestPath" "$out" \
          "$metadata/catalog.json" ${lib.getExe composer}
        mkdir -p "$out/nix-support"
        printf '%s\n' ${
          lib.escapeShellArgs (
            [ (toString src) ]
            ++ lib.concatMap (input: [
              (toString input.repository)
              (toString input.producer)
            ]) selected
          )
        } > "$out/nix-support/inputs"
      '';
in
projection
