# The Composer cache directory of a lockfile: every locked file at its
# path in Composer's cache, and every locked version-control checkout at
# its path (<kind>/<package>), as links into the store. It is a package
# for callPackage, with the lockfile and the purifier library among its
# arguments. The library fetches each entry (fetchEntry) and lays the
# entries out (tree).
#
# Composer reads it as its cache directory (COMPOSER_CACHE_DIR) when the
# cache is read-only (COMPOSER_CACHE_READ_ONLY=1): `composer install` then
# finds every dist of composer.lock in the cache and downloads nothing.
# Composer does not look at the checkouts; offline-lock.nix points the
# packages with version-control sources at them. buildComposerProject's
# `cache` is this, and `composer-purifier install` builds it on its own for
# an install outside Nix.
#
# Each version-control checkout is what Composer's downloader of that kind
# installs, from the options that src/functions.php records in the entry:
# git without submodules, since Composer's GitDownloader never runs
# `git submodule`; hg with subrepositories, since its HgDownloader runs
# `hg update`, which checks them out; svn with externals and expanded
# keywords, as the plain `svn co` of its SvnDownloader makes them.
{
  pkgs,
  lockFile,
  # The `purifier` library namespace (lib.purifier of
  # github:nix-purifiers/purifier).
  purifier,
  # Replaces nixpkgs' fetchurl for file entries: for credentials or
  # mirrors. It takes the arguments of nixpkgs' fetchurl.
  fetchurl ? null,
  # Replaces nixpkgs' fetchers of version-control checkouts, by name
  # (fetchgit, fetchhg, fetchsvn or fetchfossil): for mirrors or
  # credentials. Each takes the arguments of the nixpkgs fetcher.
  vcsFetchers ? { },
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetchers = {
    inherit pkgs;
  }
  // (if fetchurl != null then { inherit fetchurl; } else { })
  // vcsFetchers;
in
purifier.tree (
  fetchers
  // {
    name = "composer-cache";
    entries = lock.artifacts;
  }
)
// {
  inherit lock;
  # The store path of one entry of the lockfile.
  fetch = purifier.fetchEntry fetchers;
}
