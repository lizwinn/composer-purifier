# composer-purifier

composer-purifier builds Composer projects with Nix. It records what
`composer install` needs for the packages of `composer.lock` in a second
lockfile, `composer-purifier.lock.json`, with the hash of each download.
Nix fetches those downloads, and `composer install` then runs in the Nix
sandbox with the network disabled. The project commits no generated Nix
files.

The design is the one of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier) (formerly
sbt-nix-backend): the build tool keeps planning the build, a lock run
records every download by URL and hash, and Nix builds from that record
in its sandbox. sbt-nix-backend took its model from nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## Use

Write the lockfile from the directory of `composer.json`, after
`composer update` has written `composer.lock`:

```zsh
nix run github:nix-purifiers/composer-purifier -- lock
```

`lock` first runs `composer audit --locked`, online, and stops if Composer
reports a problem with a locked package. The audit follows the `audit`
and `policy` settings of `composer.json`. `lock --no-audit` skips it.

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
wrapper in `bin/`.

Nix knows every output of the project when it evaluates, from
`composer.json` alone, which it reads as JSON:

- `bins.<name>` is a package for each entry of the `bin` list, holding only
  that executable.
- `artifacts."<name>-<version>.zip"` is the dist archive that `composer
  archive` makes (see [Publishing](#publishing)).

A Composer project is one package, so these are all its outputs. `nix/lib/build-composer-project.nix` documents the
builder's arguments: `php`, `dev` (installs the `require-dev` packages),
`noScripts`, `composerFlags`, `pathRepositories`, `fetchurl` and
`vcsFetchers` (for credentials or mirrors), and `srcFilter`.

### Sources

Every kind of package source that `composer.lock` can hold builds, except
Perforce:

- A dist, the archive that Packagist and most repositories serve, is
  recorded by its URL. This covers `zip`, `tar`, `gzip`, `xz`, `rar`,
  `phar` and `file` dists, from any repository, including `package`
  repositories that name an archive URL. Nix puts the file at its path in
  Composer's cache, where `composer install` looks for it.
- A package that `composer.lock` gives only a git, hg, svn or fossil
  source is recorded as a checkout of the locked revision, with the hash
  that the nixpkgs fetcher of that kind (`fetchgit`, `fetchhg`, `fetchsvn`,
  `fetchfossil`) checks. The install takes it from the checkout as a
  `path` dist. Each checkout matches what Composer's downloader of that
  kind installs. A git checkout has no submodules, because Composer never
  runs `git submodule`. An hg checkout has its subrepositories, because
  `hg update` checks them out. An svn checkout has its externals and
  expanded keywords, as `svn checkout` makes them.
- A git source at an SSH URL is recorded under the HTTPS URL of the same
  host, because the Nix sandbox has no SSH keys. A private repository needs
  a `fetchgit` with credentials, passed as `vcsFetchers.fetchgit`.
- A `path` repository inside the project directory is part of the project
  source. One outside it, such as `../lib`, goes to the builder as
  `pathRepositories."../lib" = ../lib;`, since the build copies only the
  project directory into the store.
- A Perforce source makes `lock` fail with the package name. A Perforce
  depot has no anonymous protocol that a fetcher could use, needs a server
  and credentials, and nixpkgs has no fetcher for it.

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

`install` builds three things with `nix-build`: the Composer cache of the
lockfile, Composer on the project's PHP, and the `composer.lock` of an
offline install. It then runs `composer install` offline. Its arguments go
to `composer install`. Composer reads that `composer.lock` and a copy of
`composer.json` from `.composer-purifier/`, which also holds GC roots for
the store paths and belongs in `.gitignore`. A package that the lockfile
does not name fails to install, because the network is disabled.

### Publishing

```zsh
nix run github:nix-purifiers/composer-purifier -- archive dist
```

`archive` builds the dist archive of the project in the Nix sandbox, with
`composer archive`, and copies the zip file into the given directory. The
builder's `archive` attribute is the same archive. Packagist publishes a
package from the tags of its git repository and takes no uploads, so for
Packagist, publishing means pushing a tag. A private repository that takes
uploaded archives, such as a GitLab package registry or a Satis artifact
directory, takes this file.

## How the lock is made

`lock` loads Composer as a library and reads the locked packages the way
`composer install` does. For each package with a dist, it computes the URL
that `composer install` downloads from, using Composer's own
`Url::updateDistReference`. It then computes the path at which Composer
keeps that download in its files cache, `files/<package>/<sha1 of the
URL>.<dist type>`. It downloads each file through Composer's HTTP client,
so the credentials of `auth.json` apply, and checks the file against the
`shasum` of `composer.lock` where there is one. For each version-control
source, it builds the nixpkgs fetcher of that kind with a placeholder hash,
and records the hash that the fetcher reports. The lockfile holds each
entry with its hash, and the hash of `composer.lock`.

A lockfile made from the current `composer.lock` is left unchanged. After a
change, `lock` keeps the hashes of downloads the old lockfile already names
and fetches only new ones. `lock --force` writes the lockfile again
regardless. A relock from the same `composer.lock` writes the same bytes.

The lockfile also maps every package of `composer.lock` to its download,
in its `packages` field. The downloads are the entries of the shared
[purifier](https://github.com/nix-purifiers/purifier) library, which
fetches them and lays them out in Composer's cache directory.

## Errors

The Nix build and `composer-purifier install` check the lockfile before
they use it, and each failure says what is wrong and which command fixes
it:

| Mistake | Message |
| --- | --- |
| `composer.lock` changed, for example by `composer require`, and `lock` has not run since | `composer.lock changed after composer-purifier.lock.json was written. Run composer-purifier lock.` |
| The lockfile was edited and lost or gained a package | `… names no download for <package>, which composer.lock has.` or `… names <package>, which composer.lock does not have.`, followed by `Run composer-purifier lock --force to write it again.` |
| The lockfile was edited and a package points at a missing entry | `… names <path> for <package>, but has no entry at that path. Run composer-purifier lock --force …` |
| The lockfile is not valid JSON, has no `packages`, or has an entry without a hash | the problem, followed by `Run composer-purifier lock --force …` |
| The lockfile is from another version of composer-purifier | `… has lock format version <n>; this composer-purifier reads version 2. Run composer-purifier lock --force …` |
| A hash in the lockfile was edited | Nix rejects the download: `hash mismatch in fixed-output derivation`, with the locked hash and the hash of the download |
| `composer.json` changed and `composer update` has not run | `lock` stops with `composer.lock is out of date with composer.json. Run composer update --lock first.` |

## Projects tried

- [composer/composer](https://github.com/composer/composer) at its 2.10.3
  release (commit `f0de0bf`), 36 downloads with its `require-dev`
  packages. `lock` took about two seconds, the audit included, since
  Composer downloads in parallel. The `real-world-composer` check builds it
  with its locked dependencies and runs its `composer` executable.

`composer.lock` is the same on every system: Composer packages are PHP
source, and the platform requirements of `composer.lock` go to the PHP of
the build. One lockfile serves x86_64-linux and aarch64-linux alike.

## Limits

- `lock` runs with Composer plugins disabled, since `vendor` does not exist
  yet. A plugin that rewrites download URLs (`PRE_FILE_DOWNLOAD`) makes
  `composer install` look for a different cache path, and the offline
  install then fails.
- The hash of a GitHub dist is the hash of the zip archive that GitHub
  generates. If GitHub changes how it generates archives, the fetch fails
  with a hash mismatch, and `lock --force` records the new hashes.
- A test runner that downloads its own tools when it first runs works only
  with the network. symfony/phpunit-bridge's `simple-phpunit`, which
  composer/composer uses, installs PHPUnit with Composer the first time it
  runs, and that download is not part of `composer.lock`. A project that
  needs its tests to run offline requires `phpunit/phpunit` in
  `require-dev` instead.
- The offline installs set `COMPOSER_POLICY=0`, which turns off the
  install-time policy of Composer 2.10. That policy fetches malware and
  advisory lists from the package repositories, which an offline install
  cannot reach. `lock` runs the same check online, with `composer audit`.

## Tests

`nix flake check` runs the checks of `tests/default.nix` in the sandbox,
and the CI workflow runs them on each push to `main`, on an x86_64-linux
and an aarch64-linux runner. `tests/unit/functions.php` unit-tests the
URL-to-path rule, the parsing of sources and the lockfile check. Other
checks reject each faulty lockfile of `tests/derive-negative-fixtures.sh`,
relock a fixture byte for byte, and build composer/composer. The CI
workflow also builds `tests/tampered-hash.nix`, which Nix has to reject.
The fixtures are:

- `tests/fixtures/app` needs `ext-bz2`, which the default nixpkgs PHP does
  not load.
- `tests/fixtures/sources` has a git source, a tar archive at a URL, and
  path repositories inside and outside the project.
- `tests/fixtures/vcs` has git, hg, svn and fossil sources at unreachable
  URLs. The checks lock it with a stand-in for the prefetch command, and
  build it with stand-ins for the nixpkgs fetchers that check the
  arguments they get.

`tests/relock-fixtures.sh` writes the fixtures' lockfiles again.
