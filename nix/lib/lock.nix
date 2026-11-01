# Reads a composer-purifier lockfile (written by `composer-purifier lock`).
#
# The lockfile names every file and checkout that `composer install` needs
# for the packages of composer.lock:
#
#   version        the lock format version (lock-version.nix)
#   contentHash    the hash of every other field of the lockfile, so that an
#                  edit by hand fails evaluation (contentHash below)
#   composerLock   the SRI SHA-256 hash of the composer.lock it was made from
#   packages       every package of composer.lock, by name, mapped to the
#                  path of its entry in `artifacts`, or to null for a
#                  package of a path repository
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
#                  that the nixpkgs fetcher of that kind checks. These are
#                  the entries of the purifier library, which fetches them
#                  (cache.nix).
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

  relock = "Run `composer-purifier lock --force` to write it again.";
  invalid = message: throw "composer-purifier: ${toString lockFile} ${message}. ${relock}";

  # An entry has a path, a hash, and exactly one of `url` (a file) or a
  # version-control kind.
  validEntry =
    index: artifact:
    let
      kinds = builtins.filter (kind: artifact ? ${kind}) ([ "url" ] ++ vcsKinds);
    in
    if !(builtins.isAttrs artifact && artifact ? path && artifact ? hash) then
      invalid "has an entry without a path or a hash, at index ${toString index}"
    else if builtins.length kinds != 1 then
      invalid "has an entry at ${artifact.path} that is not exactly one of a file and a checkout"
    else if artifact ? url && !(artifact ? mirrors) then
      invalid "has a file entry at ${artifact.path} without `mirrors`"
    else
      true;

  valid =
    if !(builtins.isAttrs lock) then
      invalid "holds no JSON object"
    else if (lock.version or null) != supportedVersion then
      throw "composer-purifier: ${toString lockFile} has lock format version ${
        builtins.toJSON (lock.version or null)
      }; this library reads version ${toString supportedVersion}. ${relock}"
    else if !(builtins.isString (lock.composerLock or null)) then
      invalid "has no valid `composerLock` field"
    else if !(builtins.isAttrs (lock.packages or null)) then
      invalid "has no valid `packages` field"
    else if !(builtins.isList (lock.artifacts or null)) then
      invalid "has no valid `artifacts` field"
    else if
      !(builtins.all (x: x) (
        builtins.genList (index: validEntry index (builtins.elemAt lock.artifacts index)) (
          builtins.length lock.artifacts
        )
      ))
    then
      false
    else if (lock.contentHash or null) != contentHash then
      throw "composer-purifier: ${toString lockFile} was edited after `composer-purifier lock` wrote it: its content does not match its contentHash. ${relock}"
    else
      true;

  # The hash of everything in the lockfile but `contentHash`: the SRI
  # SHA-256 of its JSON as builtins.toJSON writes it, with sorted keys and
  # no whitespace. contentHash in src/functions.php computes the same hash.
  contentHash = builtins.convertHash {
    hash = builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs lock [ "contentHash" ]));
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };
in
assert valid;
lock
// {
  inherit storeName vcsKinds;

  # The artifacts by path. A version-control checkout of package
  # <vendor>/<name> is at <kind>/<vendor>/<name>.
  artifactsByPath = builtins.listToAttrs (
    map (a: {
      name = a.path;
      value = a;
    }) lock.artifacts
  );

  # True when the lockfile names an entry for every package of
  # `composerLock` (composer.lock, as an attribute set) and for no other
  # package, and every path it names has an entry. Otherwise it throws with
  # the command that fixes the lockfile. checkLock of src/functions.php
  # makes the same checks for `composer-purifier install`.
  checkCovers =
    composerLock:
    let
      locked = map (p: p.name) ((composerLock.packages or [ ]) ++ (composerLock.packages-dev or [ ]));
      named = builtins.attrNames lock.packages;
      missing = builtins.filter (name: !(lock.packages ? ${name})) locked;
      extra = builtins.filter (name: !(builtins.elem name locked)) named;
      paths = builtins.listToAttrs (
        map (a: {
          name = a.path;
          value = true;
        }) lock.artifacts
      );
      dangling = builtins.filter (
        name: lock.packages.${name} != null && !(paths ? ${lock.packages.${name}})
      ) named;
    in
    if missing != [ ] then
      invalid "names no download for ${builtins.concatStringsSep ", " missing}, which composer.lock has"
    else if extra != [ ] then
      invalid "names ${builtins.concatStringsSep ", " extra}, which composer.lock does not have"
    else if dangling != [ ] then
      let
        name = builtins.head dangling;
      in
      invalid "names ${lock.packages.${name}} for ${name}, but has no entry at that path"
    else
      true;
}
