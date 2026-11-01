# SPDX-License-Identifier: MIT
#
# The `composer-purifier` library namespace, which holds the builder and
# the lock reader of the purifier contract (github:nix-purifiers/purifier,
# CONTRACT.md):
#
#   lib.composer-purifier.buildComposerProject { pkgs, src, fetchers ? { }, ... }
#   lib.composer-purifier.readLock { src, lockFile ? ..., composerLock ? ... }
#
# nix/lib/build-composer-project.nix and nix/lib/read-lock.nix document
# their arguments and results. Both use the `purifier` library namespace,
# which this flake lists in its `projects`.
{ ... }:
{

  overlay = final: prev: {
    composer-purifier = {
      buildComposerProject = import ../../nix/lib/build-composer-project.nix {
        lib = final;
        inherit (final) purifier;
      };
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
