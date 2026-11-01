# composer-purifier

composer-purifier builds Composer projects with Nix. It records the files
that `composer install` downloads for the packages of `composer.lock` in a
second lockfile, `composer-purifier.lock.json`, with the hash of each file.
Nix fetches those files into Composer's cache layout, and `composer install`
then runs in the Nix sandbox with the network disabled. The project commits
no generated Nix files.

## Use

Write the lockfile from the directory of `composer.json`, after
`composer update` has written `composer.lock`:

```zsh
nix run github:nix-purifiers/composer-purifier -- lock
```

Commit `composer-purifier.lock.json` next to `composer.lock`. Run `lock`
again after each change to `composer.lock`. A Nix build of a project whose
lockfile was made from a different `composer.lock` fails with that message.

The flake's `overlays.default` adds `buildComposerProject` to a package set.
A package written for `callPackage` takes it by name:

```nix
# package.nix
{ buildComposerProject }:
buildComposerProject { src = ./.; }
```

```nix
{
  inputs.composer-purifier.url = "github:nix-purifiers/composer-purifier";
  inputs.nixpkgs.follows = "composer-purifier/nixpkgs";

  outputs = { nixpkgs, composer-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          composer-purifier.overlays.default
          (final: prev: { app = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.default = pkgs.app;
    };
}
```

nixpkgs has a different builder under `php.buildComposerProject`, which
takes a `vendorHash`. The overlay adds this one at the top level of the
package set.

The package holds the project with its `vendor` directory under
`share/php/<name>`, where `<name>` is the `name` of `composer.json` with
`/` replaced by `-`. Each entry of the `bin` list of `composer.json` gets a
wrapper in `bin/`. `nix/lib/build-composer-project.nix` documents the
builder's arguments: `php`, `dev` (installs the `require-dev` packages),
`noScripts`, `composerFlags`, `fetchurl` (for credentials or mirrors) and
`srcFilter`.

### PHP extensions

The default PHP of a build is the package set's `php` with every extension
that `composer.json` or a locked package requires as `ext-<name>`. An
extension that nixpkgs has under `php.extensions` is added. When nixpkgs
has no extension of that name, `composer install` reports the requirement
as unmet, and the build fails with Composer's message. The `php` argument
replaces the default.

### Installing outside Nix

```zsh
nix run github:nix-purifiers/composer-purifier -- install
```

`install` builds the Composer cache of the lockfile and Composer on the
project's PHP with `nix-build`, and runs `composer install` offline from
that cache. Its arguments go to `composer install`. It keeps both store
paths alive with GC roots in `.composer-purifier/`, which belongs in
`.gitignore`. A package that the lockfile does not name fails to install,
because the network is disabled.

## How the lock is made

`lock` loads Composer as a library and reads the locked packages the way
`composer install` does. For each package with a dist, it computes the URL
that `composer install` downloads from, using Composer's own
`Url::updateDistReference`. It then computes the path at which Composer
keeps that download in its files cache, `files/<package>/<sha1 of the
URL>.<dist type>`. It downloads each file through Composer's HTTP client,
so the credentials of `auth.json` apply, and checks the file against the
`shasum` of `composer.lock` where there is one. The lockfile holds each
file's cache path, URL and SHA-256 hash, and the hash of `composer.lock`.

A lockfile made from the current `composer.lock` is left unchanged. After a
change, `lock` keeps the hashes of URLs the old lockfile already names and
downloads only new ones. `lock --force` writes the lockfile again
regardless.

## Limits

- A package that composer.lock gives only a source, such as a git
  repository with no dist, fails `lock` with its name. composer-purifier
  locks dists only.
- `lock` runs with Composer plugins disabled, since `vendor` does not exist
  yet. A plugin that rewrites download URLs (`PRE_FILE_DOWNLOAD`) makes
  `composer install` look for a different cache path, and the offline
  install then fails.
- The hash of a GitHub dist is the hash of the zip archive that GitHub
  generates. If GitHub changes how it generates archives, the fetch fails
  with a hash mismatch, and `lock --force` records the new hashes.
- The build sets `COMPOSER_POLICY=0`, which turns off the install-time
  policy of Composer 2.10. That policy fetches malware and advisory lists
  from the package repositories, which an offline build cannot reach. The
  policy still applies when `composer update` writes `composer.lock`.

## Tests

`nix flake check` runs the checks of `tests/default.nix` in the sandbox.
`tests/fixtures/app` is a project that needs `ext-bz2`, which the default
nixpkgs PHP does not load. `tests/relock-fixtures.sh` writes the fixture's
lockfile again, with the network.
