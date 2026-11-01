# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The `composer-purifier` command: `lock` writes the lockfile, `install`
  # runs `composer install` offline from the files the lockfile names.
  composer-purifier = callPackage ./composer-purifier { };
}
