# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.composer-purifier` (`.composer-purifier`), and the builder
# `pkgs.buildComposerProject` (nix/lib/build-composer-project.nix) beside
# them, where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. nixpkgs has a different builder of the
# same name under `php`: `php.buildComposerProject` takes a `vendorHash`,
# and this one takes the project's composer-purifier.lock.json.
#
# Both take the purifier library (github:nix-purifiers/purifier): the
# builder as `lib.purifier`, and the composer-purifier command as the
# source of the library, which its nix-build calls import.
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
      buildComposerProject = final.callPackage ../../nix/lib/build-composer-project.nix {
        inherit (closure-lib) purifier;
      };
    };
}
