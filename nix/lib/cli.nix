# What the `composer-purifier` command builds, with nixpkgs and the purifier
# library from the composer-purifier package that runs the command:
#
#   cache        the Composer cache of the project (cache.nix)
#   composer     Composer on the PHP that the project requires with its
#                require-dev packages (php.nix)
#   offlineLock  the composer.lock that the composer of this package reads
#                for an offline install (offline-lock.nix), with the path
#                repositories as they are on the file system
#   release      the dist archive of the project, as buildComposerProject
#                builds it in the sandbox
#
# Arguments:
#
#   nixpkgs     the nixpkgs source directory
#   purifier    the source directory of the purifier library
#   system      the system to build for
#   projectDir  the absolute path of the directory of composer.json
#   lockFile    the absolute path of the lockfile; "" for the
#               composer-purifier.lock.json of the project directory
{
  nixpkgs,
  purifier,
  system,
  projectDir,
  lockFile ? "",
}:
let
  pkgs = import nixpkgs { inherit system; };
  library = import (/. + purifier) { inherit (pkgs) lib; };
  dir = /. + projectDir;
  lockPath = if lockFile == "" then dir + "/composer-purifier.lock.json" else /. + lockFile;
  locked = library.checkLock (
    import ./read-lock.nix { inherit (pkgs) lib; } {
      src = dir;
      lockFile = lockPath;
    }
  );
  # The PHP reads composer.json and composer.lock alone, so that
  # `composer-purifier update` gets it while the purifier lockfile is stale
  # or composer.lock does not exist yet.
  composerLockPath = dir + "/composer.lock";
  php = pkgs.callPackage ./php.nix {
    composerJson = builtins.fromJSON (builtins.readFile (dir + "/composer.json"));
    composerLock =
      if builtins.pathExists composerLockPath then
        builtins.fromJSON (builtins.readFile composerLockPath)
      else
        { };
    dev = true;
  };
  cache = pkgs.callPackage ./cache.nix {
    entries = {
      entries = library.entriesFor system locked;
      inherit (locked) byName;
    };
    purifier = library;
  };
  build = pkgs.callPackage ./build-composer-project.nix { purifier = library; };
in
{
  inherit cache;
  composer = php.packages.composer;
  offlineLock = pkgs.callPackage ./offline-lock.nix {
    composerLock = locked.lockedPackages;
    inherit (cache) entries fetch;
    rewritePaths = false;
  };
  release =
    (build {
      src = dir;
      lockFile = lockPath;
    }).release;
}
