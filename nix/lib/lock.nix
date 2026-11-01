# Reads a composer-purifier lockfile (written by `composer-purifier lock`).
#
# The lockfile names every file and checkout that `composer install` needs
# for the packages of composer.lock:
#
#   version        the lock format version (lock-version.nix)
#   composerLock   the SRI SHA-256 hash of the composer.lock it was made from
#   artifacts      one entry per download, of two kinds:
#                  a file entry { path, url, mirrors, hash } is a dist:
#                  `path` is where the file sits in Composer's cache
#                  directory, `url` is the URL Composer downloads it from
#                  first, `mirrors` are the further URLs Composer tries (the
#                  mirrors of its repository), and `hash` is its SRI
#                  SHA-256 hash;
#                  a version-control entry { path, <kind> = { url, rev, … },
#                  hash } is a package that composer.lock gives only a
#                  source of that kind (git, hg, svn or fossil): `path` is
#                  <kind>/<package>, and `hash` is the hash of the checkout
#                  that the nixpkgs fetcher of that kind checks (fetch.nix).
#                  The fetcher options of each kind are fields beside `url`
#                  and `rev`: `submodules`, `leaveDotGit` and `commitObject`
#                  for git (always false, false and null, since Composer
#                  installs a git source without submodules and the install
#                  needs no .git directory), `subrepos` for hg, and
#                  `ignoreExternals` and `ignoreKeywords` for svn
#
# Needs no nixpkgs.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  vcsKinds = [
    "git"
    "hg"
    "svn"
    "fossil"
  ];

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
  inherit storeName vcsKinds;

  # The kind of an artifact: "file", or the version-control system of a
  # checkout.
  kindOf =
    artifact:
    let
      kinds = builtins.filter (kind: artifact ? ${kind}) vcsKinds;
    in
    if kinds == [ ] then "file" else builtins.head kinds;

  # The artifacts by path. A version-control checkout of package
  # <vendor>/<name> is at <kind>/<vendor>/<name>.
  artifactsByPath = builtins.listToAttrs (
    map (a: {
      name = a.path;
      value = a;
    }) lock.artifacts
  );

  # The fetch name of an artifact: the last two parts of its path, made a
  # valid store name. A file path is
  # files/<vendor>/<package>/<sha1 of the URL>.<dist type>, and a checkout
  # path is <kind>/<vendor>/<package>.
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
