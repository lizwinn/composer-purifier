# What `composer-purifier install` builds, with nixpkgs from the
# composer-purifier package that runs the command:
#
#   cache      the Composer cache of the project's lockfile (cache.nix)
#   composer   Composer on the PHP that the project requires (php.nix), the
#              PHP buildComposerProject builds the project with
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
  dev,
}:
let
  pkgs = import nixpkgs { inherit system; };
  dir = /. + projectDir;
  php = pkgs.callPackage ./php.nix {
    composerJson = builtins.fromJSON (builtins.readFile (dir + "/composer.json"));
    composerLock = builtins.fromJSON (builtins.readFile (dir + "/composer.lock"));
    dev = dev == "1";
  };
in
{
  cache = pkgs.callPackage ./cache.nix { lockFile = dir + "/composer-purifier.lock.json"; };
  composer = php.packages.composer;
}
