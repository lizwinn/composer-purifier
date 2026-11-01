# composer-purifier

composer-purifier builds Composer projects with Nix. It records what
`composer install` needs for the packages of `composer.lock` in a second
lockfile, `composer-purifier.lock.json`, with the hash of each download.
Nix fetches those downloads, and `composer install` runs in the Nix
sandbox with the network disabled. The project commits no generated Nix
files. composer-purifier meets the
[purifier contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md),
so its builder, commands and checks have the same shape as those of the
other nix-purifiers.

## Quickstart

Write the lockfile from the directory of `composer.json`, after
`composer update` has written `composer.lock`:

```zsh
nix run github:nix-purifiers/composer-purifier -- lock
```

`lock` first runs `composer audit --locked`, online, and stops if Composer
reports a problem with a locked package. The audit follows the `audit` and
`policy` settings of `composer.json`. `lock --no-audit` skips it. Commit
`composer-purifier.lock.json` next to `composer.lock`.

The builder is in the flake's library:

```nix
{
  inputs.composer-purifier.url = "github:nix-purifiers/composer-purifier";
  inputs.nixpkgs.follows = "composer-purifier/nixpkgs";

  outputs = { nixpkgs, composer-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      app = composer-purifier.lib.composer-purifier.buildComposerProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.${system} = app.packages;
      checks.${system}.tests = app.tests;
    };
}
```

The result of `buildComposerProject` names every output from
`composer.json`, which Nix reads at evaluation time:

- `packages.<name>` is the project with its `vendor` directory under
  `share/php/<name>`, where `<name>` is the `name` of `composer.json` with
  `/` replaced by `-`. It has a wrapper in `bin/` for each entry of the
  `bin` list of `composer.json`.
- `packages.<bin>` is a package for each entry of the `bin` list, holding
  only that executable.
- `tests` runs the `test` script of `composer.json` in the sandbox, with
  the `require-dev` packages installed.
- `release` is the dist archive that `composer archive` makes,
  `<name>-<version>.zip`.
- `fetches` lists the lockfile entries that the builds fetch.

`nix/lib/build-composer-project.nix` documents the builder's arguments:
`pkgs`, `src`, `fetchers`, `lockFile`, `composerLock`, `php`, `dev`,
`noScripts`, `composerFlags`, `pathRepositories` and `srcFilter`.

A packaging flake can build a project whose source holds neither lockfile.
It writes the lockfile with `composer-purifier lock --lockfile <path>`, and
passes it as `lockFile`, with `composer.lock` as `composerLock` when the
source has none. A file given this way replaces the copy in `src`.

## Everyday loop

`nix develop github:nix-purifiers/composer-purifier` gives PHP, the
`composer-purifier` command, its `composer`, and phpactor. The loop is
Composer's own:

1. `composer-purifier prefetch` fetches what the lockfile names into the
   Nix store (see [Offline work](#offline-work)).
2. `composer install` installs the project from those downloads, offline,
   with a PHP that has the extensions the project requires.
3. The project runs as usual: its `bin` scripts with `php`, its tests with
   `composer test`.
4. `composer require` or `composer update` changes a dependency online, as
   always. `composer-purifier lock` then records the new downloads,
   reusing the hashes it already has, and `composer-purifier prefetch`
   fetches them.

The next `composer install` after a change to `composer.lock` stops until
the lockfile and the prefetch catch up, and says which command to run.

## Offline work

`composer-purifier prefetch` builds three things with `nix-build`: the
Composer cache of the lockfile, Composer on the PHP that the project
requires with its `require-dev` packages, and the `composer.lock` of an
offline install. It keeps them alive with GC roots in `.composer-purifier/`,
which belongs in `.gitignore`. The `require-dev` packages are part of the
prefetch, so the tests run offline too.

After a prefetch, the `composer` of this flake reads `.composer-purifier/`
for `composer install`, and runs it with the network disabled. Every other
subcommand is plain Composer. A package that the lockfile does not name
fails to install offline, because the network is disabled.

## Editor

PHP editors and language servers, such as phpactor and Intelephense, read
the project's `vendor` directory. A Composer dist holds the full source of
its package, so `composer install` after a prefetch gives the editor
everything, with no separate source downloads. The development shell has
phpactor.

## Errors and fixes

The Nix build, `composer-purifier prefetch` and the offline
`composer install` check the lockfile before they use it. Each failure says
what is wrong and which command fixes it:

| Mistake | Message |
| --- | --- |
| `composer.lock` changed, for example by `composer require`, and `lock` has not run since | `composer.lock changed after composer-purifier.lock.json was written. Run composer-purifier lock.` |
| The lockfile changed after the last prefetch | `composer-purifier.lock.json changed after the last prefetch. Run composer-purifier prefetch.` |
| The lockfile was edited by hand, a hash included | `… was edited after composer-purifier lock wrote it: its content does not match its contentHash. Run composer-purifier lock --force to write it again.` |
| The lockfile lost or gained a package | `… names no download for <package>, which composer.lock has.` or `… names <package>, which composer.lock does not have.`, followed by `Run composer-purifier lock --force …` |
| A package points at a missing entry | `… names <path> for <package>, but has no entry at that path. Run composer-purifier lock --force …` |
| The lockfile is not valid JSON, has no `packages`, or has an entry without a hash | the problem, followed by `Run composer-purifier lock --force …` |
| The lockfile is from another version of composer-purifier | `… has lock format version <n>; this composer-purifier reads version 3. Run composer-purifier lock --force …` |
| A download no longer matches its locked hash | Nix rejects it with `hash mismatch in fixed-output derivation`, naming both hashes |
| `composer.json` changed and `composer update` has not run | `lock` stops with `composer.lock is out of date with composer.json. Run composer update --lock first.` |

The lockfile holds `contentHash`, the SHA-256 of its other fields, so an
edit by hand fails before any download.

## Sources supported and refused

Every kind of package source that `composer.lock` can hold builds, except
Perforce.

- A dist, the archive that Packagist and most repositories serve, is
  recorded by its URL and the mirrors of its repository. This covers `zip`,
  `tar`, `gzip`, `xz`, `rar`, `phar` and `file` dists, from any repository,
  including `package` repositories that name an archive URL. Nix puts the
  file at its path in Composer's cache, where `composer install` looks for
  it.
- A package that `composer.lock` gives only a git, hg, svn or fossil
  source is recorded as a checkout of the locked revision, with the hash
  that the nixpkgs fetcher of that kind checks. The install takes it from
  the checkout as a `path` dist. Each checkout matches what Composer's
  downloader of that kind installs. A git checkout has no submodules,
  because Composer never runs `git submodule`. An hg checkout has its
  subrepositories, because `hg update` checks them out. An svn checkout has
  its externals and expanded keywords, as `svn checkout` makes them.
- A git source at an SSH URL is recorded under the HTTPS URL of the same
  host, because the Nix sandbox has no SSH keys. A private repository needs
  a `fetchgit` with credentials, passed as `fetchers.fetchgit`.
- A `path` repository inside the project directory is part of the project
  source. One outside it, such as `../lib`, goes to the builder as
  `pathRepositories."../lib" = ../lib;`, since the build copies only the
  project directory into the store.
- A Perforce source makes `lock` fail with the package name. A Perforce
  depot has no anonymous protocol that a fetcher could use, needs a server
  and credentials, and nixpkgs has no fetcher for it.

`composer.lock` is the same on every system: Composer packages are PHP
source, and the platform requirements of `composer.lock` go to the PHP of
the build. One lockfile serves x86_64-linux and aarch64-linux alike.

The default PHP of a build is the package set's `php` with every extension
that `composer.json` or a locked package requires as `ext-<name>`. An
extension that nixpkgs has under `php.extensions` is added. When nixpkgs
has no extension of that name, `composer install` reports the requirement
as unmet, and the build fails with Composer's message. The `php` argument
replaces the default.

`composer-purifier publish <directory>` copies the `release` that Nix built
into a directory, such as that of a Composer `artifact` repository or a
Satis build. Packagist publishes a package from the tags of its git
repository and takes no uploads, so for Packagist, publishing means
pushing a tag.

Other limits:

- `lock` runs with Composer plugins disabled, since `vendor` does not exist
  yet. A plugin that rewrites download URLs (`PRE_FILE_DOWNLOAD`) makes
  `composer install` look for a different cache path, and the offline
  install then fails.
- A test runner that downloads its own tools when it first runs works only
  with the network. The `simple-phpunit` of symfony/phpunit-bridge, which
  composer/composer uses, installs PHPUnit with Composer the first time it
  runs, and that download is not part of `composer.lock`. A project whose
  tests run offline requires `phpunit/phpunit` in `require-dev` instead.
- The hash of a GitHub dist is the hash of the zip archive that GitHub
  generates. If GitHub changes how it generates archives, the fetch fails
  with a hash mismatch, and `lock --force` records the new hashes.
- The offline installs set `COMPOSER_POLICY=0`, which turns off the
  install-time policy of Composer 2.10. That policy fetches malware and
  advisory lists from the package repositories, which an offline install
  cannot reach. `lock` runs the same check online, with `composer audit`.

## Real-world projects

- [composer/composer](https://github.com/composer/composer) at its 2.10.3
  release (commit `f0de0bf`), 36 downloads with its `require-dev`
  packages. `lock` took about two seconds, the audit included, since
  Composer downloads in parallel. The `real-world-composer` check builds it
  from `tests/projects/composer/composer-purifier.lock.json` and runs its
  `composer` executable.

`nix flake check` runs the checks of `tests/default.nix`, and the CI
workflow runs them on each push to `main`, on an x86_64-linux and an
aarch64-linux runner. They include the `conformance-*` checks of the
contract, unit tests of the lock run's URL-to-path rule, source parsing and
lockfile checks (`tests/unit/functions.php`), and a fixture for each kind
of source.

## Credits

composer-purifier follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier), formerly
sbt-nix-backend: the build tool keeps planning the build, a lock run
records every download by URL and hash, and Nix builds from that record in
its sandbox. sbt-nix-backend took its model from nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo). The downloads are the
entries of the shared [purifier](https://github.com/nix-purifiers/purifier)
library, which fetches them and lays them out.
