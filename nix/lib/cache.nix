# The Composer cache directory of a lockfile: every locked file at its
# path in Composer's cache, and every locked version-control checkout at
# its path (<kind>/<package>), as links into the store. It is a package
# for callPackage, with the lockfile among its arguments.
#
# Composer reads it as its cache directory (COMPOSER_CACHE_DIR) when the
# cache is read-only (COMPOSER_CACHE_READ_ONLY=1): `composer install` then
# finds every dist of composer.lock in the cache and downloads nothing.
# Composer does not look at the checkouts; offline-lock.nix points the
# packages with version-control sources at them. buildComposerProject's
# `cache` is this, and `composer-purifier install` builds it on its own for
# an install outside Nix.
{
  lib,
  runCommand,
  fetchgit,
  fetchhg,
  fetchsvn,
  fetchfossil,
  lockFile,
  # Replaces the built-in fetcher of file entries; see fetch.nix.
  fetchurl ? null,
  # Replaces nixpkgs' fetchers of version-control checkouts, by name
  # (fetchgit, fetchhg, fetchsvn or fetchfossil): for mirrors or
  # credentials. Each takes the arguments of the nixpkgs fetcher.
  vcsFetchers ? { },
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix {
    inherit lock fetchurl;
    vcsFetchers = {
      inherit
        fetchgit
        fetchhg
        fetchsvn
        fetchfossil
        ;
    }
    // vcsFetchers;
  };
in
# The manifest goes to the builder as a file, since a large project locks
# hundreds of archives and the list would not fit in an environment
# variable.
runCommand "composer-cache"
  {
    manifest = lib.concatMapStrings (a: "${a.path}\t${fetch a}\n") lock.artifacts;
    passAsFile = [ "manifest" ];
    preferLocalBuild = true;
    allowSubstitutes = false;
    passthru = { inherit lock fetch; };
  }
  ''
    mkdir -p $out
    while IFS=$'\t' read -r rel target; do
      mkdir -p "$out/$(dirname "$rel")"
      ln -s "$target" "$out/$rel"
    done < "$manifestPath"
  ''
