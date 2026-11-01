# buildComposerProject: the sandboxed build of a Composer project, from the
# lockfile that `composer-purifier lock` writes next to composer.lock.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# composer-purifier overlay (`overlays.default`) adds it to the package set
# as `buildComposerProject`, so a package written for callPackage takes it
# like any other dependency:
#
#   { buildComposerProject }: buildComposerProject { src = ./.; }
#
# and `buildComposerProject.override` replaces what it takes from the set.
#
# The build runs `composer install` in the Nix sandbox, offline, with the
# Composer cache of the lockfile (cache.nix). The package holds the project
# with its `vendor` directory under share/php/<name>, and a wrapper in bin/
# for each entry of the `bin` list of composer.json. Its passthru holds
# `cache`, `lock` and the `php` it built with.
{
  lib,
  stdenvNoCC,
  callPackage,
  makeBinaryWrapper,
  # The PHP that the default PHP of a build adds extensions to.
  php,
}@setArgs:
{
  # The root of the Composer project: the directory of composer.json.
  src,
  # The lockfile; the default is the one `composer-purifier lock` writes
  # next to composer.lock.
  lockFile ? src + "/composer-purifier.lock.json",
  # The PHP the project builds and runs with. The default is the package
  # set's `php` with the extensions the project requires (php.nix).
  php ? null,
  # Installs the require-dev packages too.
  dev ? false,
  # Skips the scripts of composer.json (`--no-scripts`).
  noScripts ? false,
  # Further arguments of `composer install`.
  composerFlags ? [ ],
  # Replaces the built-in fetcher; see fetch.nix.
  fetchurl ? null,
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out `vendor` and `.git`.
  srcFilter ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  cache = callPackage ./cache.nix { inherit lockFile fetchurl; };

  composerJson = builtins.fromJSON (builtins.readFile (src + "/composer.json"));
  composerLockFile = src + "/composer.lock";
  composerLock = builtins.fromJSON (builtins.readFile composerLockFile);

  composerLockHash = builtins.convertHash {
    hash = builtins.hashFile "sha256" composerLockFile;
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };

  buildPhp =
    if php != null then
      php
    else
      callPackage ./php.nix {
        inherit (setArgs) php;
        inherit composerJson composerLock dev;
      };
  composer = buildPhp.packages.composer;

  # `vendor/name` becomes the package name `vendor-name`.
  pname = lock.storeName (
    builtins.replaceStrings [ "/" ] [ "-" ] (composerJson.name or (baseNameOf (toString src)))
  );

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !((type == "directory" && name == "vendor") || name == ".git" || name == ".composer-purifier");

  source = builtins.path {
    path = src;
    name = "${pname}-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  installFlags = [
    "--no-interaction"
    "--no-progress"
    "--optimize-autoloader"
  ]
  ++ lib.optional (!dev) "--no-dev"
  ++ lib.optional noScripts "--no-scripts"
  ++ composerFlags;

  bins = composerJson.bin or [ ];
in
assert
  composerLockHash == lock.composerLock
  || throw "composer-purifier: ${toString lockFile} was made from a different composer.lock. Run `composer-purifier lock` in ${toString src}.";
stdenvNoCC.mkDerivation {
  inherit pname;
  version = composerJson.version or "0";
  src = source;

  strictDeps = true;
  nativeBuildInputs = [
    buildPhp
    composer
    makeBinaryWrapper
  ];

  dontConfigure = true;

  # Composer reads the locked dists from the read-only cache, and the
  # disabled network makes any other download fail the build rather than
  # reach out.
  #
  # COMPOSER_POLICY=0 turns off the install-time policy of Composer 2.10,
  # which fetches malware and advisory lists from the package repositories.
  # Those lists change over time, so an offline build cannot use them. The
  # policy still applies when `composer update` writes composer.lock.
  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR/home"
    export COMPOSER_HOME="$TMPDIR/composer-home"
    export COMPOSER_CACHE_DIR=${cache}
    export COMPOSER_CACHE_FILES_DIR=${cache}/files
    export COMPOSER_CACHE_READ_ONLY=1
    export COMPOSER_DISABLE_NETWORK=1
    export COMPOSER_POLICY=0
    export COMPOSER_HTACCESS_PROTECT=0
    composer install ${lib.escapeShellArgs installFlags}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    dir="$out/share/php/${pname}"
    mkdir -p "$dir"
    cp -r . "$dir"
    ${lib.concatMapStrings (bin: ''
      makeWrapper ${lib.getExe buildPhp} "$out/bin/${baseNameOf bin}" \
        --add-flags "$dir/${bin}"
    '') bins}
    runHook postInstall
  '';

  passthru = {
    inherit cache lock;
    php = buildPhp;
  };

  meta = lib.optionalAttrs (bins != [ ]) { mainProgram = baseNameOf (builtins.head bins); };
}
