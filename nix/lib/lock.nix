# Reads a composer-purifier lockfile (written by `composer-purifier lock`).
#
# The lockfile names every file `composer install` downloads for the
# packages of composer.lock:
#
#   version        the lock format version (lock-version.nix)
#   composerLock   the SRI SHA-256 hash of the composer.lock it was made from
#   artifacts      one entry per download: `path` is where the file sits in
#                  Composer's cache directory, `url` is the URL Composer
#                  downloads it from, and `hash` is its SRI SHA-256 hash
#
# Needs no nixpkgs.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  # A store path name from a file name. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters; every other character becomes "_".
  storeName =
    fileName:
    let
      # builtins.split alternates the text between matches with a list per
      # match.
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (
          builtins.split "[^A-Za-z0-9+._?=-]" fileName
        )
      );
      undotted = builtins.head (builtins.match "\\.*(.*)" replaced);
      nonEmpty = if undotted == "" then "file" else undotted;
    in
    builtins.substring 0 200 nonEmpty;
in
assert
  lock.version == supportedVersion
  || throw "composer-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `composer-purifier lock` with the composer-purifier version that provides this library.";
lock
// {
  inherit storeName;

  # The fetch name of an artifact: the package name and the cache file
  # name, made a valid store name. A cache path is
  # files/<vendor>/<package>/<sha1 of the URL>.<dist type>.
  artifactName =
    artifact:
    let
      parts = builtins.filter builtins.isString (builtins.split "/" artifact.path);
      count = builtins.length parts;
      package = builtins.elemAt parts (count - 2);
      file = builtins.elemAt parts (count - 1);
    in
    storeName "${package}-${file}";
}
