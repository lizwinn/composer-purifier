# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.composer-purifier` (`.composer-purifier`), and the builder
# `pkgs.buildComposerProject` (nix/lib/build-composer-project.nix) beside
# them, where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. nixpkgs has a different builder of the
# same name under `php`: `php.buildComposerProject` takes a `vendorHash`,
# and this one takes the project's composer-purifier.lock.json.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "composer-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildComposerProject = final.callPackage ../../nix/lib/build-composer-project.nix { };
    };
}
