# What the `composer-purifier` command builds, with nixpkgs from the
# composer-purifier package that runs the command:
#
#   cache        the Composer cache of the project's lockfile (cache.nix)
#   composer     Composer on the PHP that the project requires (php.nix),
#                the PHP buildComposerProject builds the project with
#   offlineLock  the composer.lock that `install` reads (offline-lock.nix),
#                with the path repositories as they are on the file system
#   archive      the project's dist archive, as buildComposerProject builds
#                it in the sandbox
#
# Arguments:
#
#   nixpkgs     the nixpkgs source directory
#   system      the system to build for
#   projectDir  the absolute path of the directory of composer.json
#   dev         "1" when the install includes the require-dev packages
{
  nixpkgs,
  system,
  projectDir,
  dev ? "1",
}:
let
  pkgs = import nixpkgs { inherit system; };
  dir = /. + projectDir;
  composerLock = builtins.fromJSON (builtins.readFile (dir + "/composer.lock"));
  php = pkgs.callPackage ./php.nix {
    composerJson = builtins.fromJSON (builtins.readFile (dir + "/composer.json"));
    inherit composerLock;
    dev = dev == "1";
  };
  cache = pkgs.callPackage ./cache.nix { lockFile = dir + "/composer-purifier.lock.json"; };
in
{
  inherit cache;
  composer = php.packages.composer;
  offlineLock = pkgs.callPackage ./offline-lock.nix {
    inherit composerLock;
    inherit (cache) lock fetch;
    rewritePaths = false;
  };
  archive = ((pkgs.callPackage ./build-composer-project.nix { }) { src = dir; }).archive;
}
