# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.composer-purifier`: `.composer-purifier`, the command with `lock`,
# `update`, `prefetch` and `publish`, and the `composer` that runs a
# prefetched install offline. It adds the builder `pkgs.buildComposerProject`
# (nix/lib/build-composer-project.nix) beside them, where nixpkgs keeps its
# own builders, so a package written for callPackage takes it by name.
#
# The builder and the command take the purifier library
# (github:nix-purifiers/purifier) of this flake's pin: the builder as the
# library itself, the command as the source its nix-build calls import.
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
      buildComposerProject = final.callPackage ../../nix/lib/build-composer-project.nix {
        purifier = import closure-inputs.purifier { inherit (final) lib; };
      };
      composer-purifier = added.composer-purifier // {
        composer-purifier = added.composer-purifier.composer-purifier.override {
          purifierSource = closure-inputs.purifier;
        };
      };
    };
}
