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
# Composer cache of the lockfile (cache.nix) and the composer.lock of
# offline-lock.nix. The package holds the project with its `vendor`
# directory under share/php/<name>, and a wrapper in bin/ for each entry of
# the `bin` list of composer.json. Nix knows every output of the project
# from composer.json, which it reads as JSON, without building anything:
#
#   bins.<name>              one package per entry of `bin`, holding only
#                            that executable
#   artifacts."<file name>"  each published file: the dist archive that
#                            `composer archive` makes, <name>-<version>.zip
#   archive                  the directory that holds the dist archive
#
# Its passthru also holds `cache`, `lock` and the `php` it built with.
{
  lib,
  stdenvNoCC,
  callPackage,
  runCommand,
  makeBinaryWrapper,
  # The PHP that the default PHP of a build adds extensions to.
  php,
  # The `purifier` library namespace (lib.purifier of
  # github:nix-purifiers/purifier), which fetches the lockfile entries.
  purifier,
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
  # The Nix path of each `path` repository outside the project directory,
  # by the URL that composer.json gives it: { "../lib" = ../lib; }.
  pathRepositories ? { },
  # Replaces nixpkgs' fetchurl for dists; see cache.nix.
  fetchurl ? null,
  # Replaces nixpkgs' fetchers of version-control checkouts, by name; see
  # cache.nix.
  vcsFetchers ? { },
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out `vendor` and `.git`.
  srcFilter ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  cache = callPackage ./cache.nix {
    inherit
      lockFile
      fetchurl
      vcsFetchers
      purifier
      ;
  };

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

  offlineLock = callPackage ./offline-lock.nix {
    inherit composerLock pathRepositories;
    inherit (cache) lock fetch;
    rewritePaths = true;
  };

  # The environment of every Composer run in the sandbox. Composer reads
  # the locked dists from the read-only cache, and the disabled network
  # makes any other download fail the build rather than reach out.
  #
  # COMPOSER_POLICY=0 turns off the install-time policy of Composer 2.10,
  # which fetches malware and advisory lists from the package repositories.
  # Those lists change over time, so an offline build cannot use them.
  # `composer-purifier lock` runs `composer audit` online instead.
  composerEnvironment = ''
    export HOME="$TMPDIR/home"
    export COMPOSER_HOME="$TMPDIR/composer-home"
    export COMPOSER_CACHE_DIR=${cache}
    export COMPOSER_CACHE_FILES_DIR=${cache}/files
    export COMPOSER_CACHE_READ_ONLY=1
    export COMPOSER_DISABLE_NETWORK=1
    export COMPOSER_POLICY=0
    export COMPOSER_HTACCESS_PROTECT=0
  '';

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

  version = composerJson.version or "0";

  # composer.json gives `bin` as one path or as a list of paths.
  bins = lib.toList (composerJson.bin or [ ]);
  binName = bin: baseNameOf bin;

  # The file that `composer archive` writes: <file>.<format>.
  archiveFileName = "${pname}-${version}.zip";

  archive = stdenvNoCC.mkDerivation {
    pname = "${pname}-archive";
    inherit version;
    src = source;
    strictDeps = true;
    nativeBuildInputs = [
      buildPhp
      composer
    ];
    dontConfigure = true;
    dontFixup = true;
    # `composer archive` packs the root package from the project source,
    # leaving out what composer.json's `archive.exclude` and the
    # export-ignore attributes of .gitattributes name.
    buildPhase = ''
      runHook preBuild
      ${composerEnvironment}
      mkdir -p $out
      composer archive --no-interaction --format=zip --dir=$out --file=${pname}-${version}
      test -f $out/${archiveFileName}
      runHook postBuild
    '';
    dontInstall = true;
  };
in
assert
  composerLockHash == lock.composerLock
  || throw "composer-purifier: composer.lock changed after ${toString lockFile} was written. Run `composer-purifier lock` in ${toString src}.";
assert lock.checkCovers composerLock;
stdenvNoCC.mkDerivation (finalAttrs: {
  inherit pname version;
  src = source;

  strictDeps = true;
  nativeBuildInputs = [
    buildPhp
    composer
    makeBinaryWrapper
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    ${composerEnvironment}
    cp --no-preserve=mode ${offlineLock} composer.lock
    composer install ${lib.escapeShellArgs installFlags}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    dir="$out/share/php/${pname}"
    mkdir -p "$dir"
    cp -r . "$dir"
    ${lib.concatMapStrings (bin: ''
      makeWrapper ${lib.getExe buildPhp} "$out/bin/${binName bin}" \
        --add-flags "$dir/${bin}"
    '') bins}
    runHook postInstall
  '';

  # The outputs of the project, by name, from composer.json alone, so that
  # Nix knows them before it builds anything.
  passthru = {
    inherit cache lock archive;
    php = buildPhp;

    # One package per entry of the `bin` list of composer.json, holding
    # only that executable.
    bins = lib.listToAttrs (
      map (
        bin:
        lib.nameValuePair (binName bin) (
          runCommand "${pname}-${binName bin}" { meta.mainProgram = binName bin; } ''
            mkdir -p $out/bin
            ln -s ${finalAttrs.finalPackage}/bin/${binName bin} $out/bin/${binName bin}
          ''
        )
      ) bins
    );

    # The published files of the project, by file name: the dist archive.
    artifacts.${archiveFileName} = "${archive}/${archiveFileName}";
  };

  meta = lib.optionalAttrs (bins != [ ]) { mainProgram = binName (builtins.head bins); };
})
