# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.composer-purifier`: `.composer-purifier`, the command with `lock`,
# `prefetch` and `publish`, and the `composer` that runs a prefetched
# install offline. The builder is in the library, as
# lib.composer-purifier.buildComposerProject (lib-overlays/default).
#
# The command takes the source of the purifier library
# (github:nix-purifiers/purifier), which its nix-build calls import.
{ closure-lib, closure-inputs, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "composer-purifier";
in
{
  overlay =
    final: prev:
    let
      added = packages final prev;
    in
    added
    // {
      composer-purifier = added.composer-purifier // {
        composer-purifier = added.composer-purifier.composer-purifier.override {
          purifierSource = closure-inputs.purifier;
        };
      };
    };
}
