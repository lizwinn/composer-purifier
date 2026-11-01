# SPDX-License-Identifier: MIT
#
# The `composer-purifier` library namespace, which holds the builder of the
# purifier contract (github:nix-purifiers/purifier, CONTRACT.md):
#
#   lib.composer-purifier.buildComposerProject { pkgs, src, fetchers ? { }, ... }
#
# nix/lib/build-composer-project.nix documents its arguments and its
# result. It fetches through the `purifier` library namespace, which this
# flake lists in its `projects`.
{ ... }:
{

  overlay = final: prev: {
    composer-purifier = {
      buildComposerProject = import ../../nix/lib/build-composer-project.nix {
        lib = final;
        inherit (final) purifier;
      };
    };
  };

}
