# The fetcher for locked artifacts.
#
# A file entry is by default a fixed-output derivation on Nix's built-in
# fetcher (the same derivation <nix/fetchurl.nix> makes), which tries
# `url` and then each of `mirrors`. A fixed-output store path depends only
# on its name and hash, so the default fetcher and nixpkgs' fetchurl
# produce the same paths. `fetchurl`, when given, replaces the built-in
# fetcher. It is called with { name, urls, hash } and is the place for
# credentials (nixpkgs' fetchurl takes `netrcPhase`).
#
# A version-control entry is a checkout by the nixpkgs fetcher of its
# kind, from `vcsFetchers` (fetchgit, fetchhg, fetchsvn and fetchfossil).
# Each checkout is what Composer's downloader of that kind installs:
#
#   git     no submodules, since Composer's GitDownloader never runs
#           `git submodule`
#   hg      with subrepositories, since Composer's HgDownloader runs
#           `hg update`, which checks them out
#   svn     with externals and expanded keywords, as `svn checkout` makes
#           them for Composer's SvnDownloader
#   fossil  the checkout of `fossil update` in Composer's FossilDownloader
{
  lock,
  fetchurl ? null,
  vcsFetchers ? { },
}:
artifact:
let
  name = lock.artifactName artifact;
  kind = lock.kindOf artifact;
  urls = [ artifact.url ] ++ artifact.mirrors;
  source = artifact.${kind};
  fetcher =
    vcsFetchers."fetch${kind}"
      or (throw "composer-purifier: ${artifact.path} is a ${kind} checkout, and fetching it needs nixpkgs' fetch${kind}.");
in
if kind == "git" then
  fetcher {
    inherit name;
    inherit (source) url rev;
    fetchSubmodules = source.submodules;
    inherit (artifact) hash;
  }
else if kind == "hg" then
  fetcher {
    inherit name;
    inherit (source) url rev;
    fetchSubrepos = source.subrepos;
    inherit (artifact) hash;
  }
else if kind == "svn" then
  fetcher {
    inherit name;
    inherit (source) url rev;
    inherit (artifact) hash;
  }
else if kind == "fossil" then
  fetcher {
    inherit name;
    inherit (source) url rev;
    outputHash = artifact.hash;
  }
else if fetchurl != null then
  fetchurl {
    inherit name urls;
    inherit (artifact) hash;
  }
else
  derivation {
    inherit name urls;
    builder = "builtin:fetchurl";
    system = "builtin";
    inherit (artifact) url;
    outputHash = artifact.hash;
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    unpack = false;
    executable = false;
    preferLocalBuild = true;
    impureEnvVars = [
      "http_proxy"
      "https_proxy"
      "ftp_proxy"
      "all_proxy"
      "no_proxy"
    ];
  }
