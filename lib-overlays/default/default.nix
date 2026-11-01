# SPDX-License-Identifier: MIT
#
# The `composer-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildComposerProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    composer-purifier = prev.composer-purifier or { };
  };

}
