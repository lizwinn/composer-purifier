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
  lock = import ../nix/lib/lock.nix { lockFile = ./fixtures/edited/tampered-hash.json; };
  fetch = import ../nix/lib/fetch.nix { inherit lock; };
in
fetch lock.artifactsByPath."files/monolog/monolog/13f7456348238a63d970854498776d96f53cdee8.zip"
