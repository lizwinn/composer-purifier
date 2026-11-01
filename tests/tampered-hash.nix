# SPDX-License-Identifier: MIT
#
# The fetch of the monolog entry of tests/fixtures/edited/tampered-hash.json,
# whose hash is the one of psr/log. Building it has to fail: Nix downloads
# monolog and rejects it with "hash mismatch in fixed-output derivation".
# The CI workflow builds it and expects that failure, since a check cannot
# run a build that must fail.
#
#   nix build --file tests/tampered-hash.nix --no-link
let
  flake = builtins.getFlake (toString ./..);
  pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  lock = import ../nix/lib/lock.nix { lockFile = ./fixtures/edited/tampered-hash.json; };
in
flake.inputs.purifier.lib.purifier.fetchEntry {
  inherit pkgs;
} lock.artifactsByPath."files/monolog/monolog/13f7456348238a63d970854498776d96f53cdee8.zip"
