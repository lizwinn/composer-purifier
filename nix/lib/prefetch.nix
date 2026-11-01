# What `composer-purifier lock` builds to learn the hash of a checkout: the
# fetcher of fetch.nix for that checkout, with a fake hash. The build
# fetches the checkout and fails with the hash it got, which
# composer-purifier-prefetch reads. The hash is then exactly the one the
# fetcher checks in a build.
#
#   nixpkgs    the nixpkgs source directory
#   system     the system to build for
#   kind       git, hg, svn or fossil
#   checkout   the checkout of the lockfile entry, as JSON
{
  nixpkgs,
  system,
  kind,
  checkout,
}:
let
  pkgs = import nixpkgs { inherit system; };
  lock = import ./lock.nix {
    lockFile = builtins.toFile "composer-purifier.lock.json" (
      builtins.toJSON {
        version = import ./lock-version.nix;
        composerLock = "";
        packages = { };
        artifacts = [ ];
      }
    );
  };
  fetch = import ./fetch.nix {
    inherit lock;
    vcsFetchers = {
      inherit (pkgs)
        fetchgit
        fetchhg
        fetchsvn
        fetchfossil
        ;
    };
  };
in
fetch {
  path = "${kind}/prefetch/checkout";
  ${kind} = builtins.fromJSON checkout;
  hash = pkgs.lib.fakeHash;
}
