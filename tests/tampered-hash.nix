# SPDX-License-Identifier: MIT
#
# The fetch of the monolog entry of tests/fixtures/edited/tampered-hash.json,
# whose hash is the one of psr/log. Evaluation of the lockfile rejects the
# edit by its content hash; this fetch takes the entry without that check,
# to show that Nix rejects the download too: building it fails with "hash
# mismatch in fixed-output derivation". The CI workflow builds it and
# expects that failure, since a check cannot run a build that must fail.
#
#   nix build --file tests/tampered-hash.nix --no-link
let
  flake = builtins.getFlake (toString ./..);
  pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  lock = builtins.fromJSON (builtins.readFile ./fixtures/edited/tampered-hash.json);
  monolog = builtins.head (
    builtins.filter (
      a: a.path == "files/monolog/monolog/13f7456348238a63d970854498776d96f53cdee8.zip"
    ) lock.artifacts
  );
in
flake.inputs.purifier.lib.purifier.fetchEntry { inherit pkgs; } monolog
