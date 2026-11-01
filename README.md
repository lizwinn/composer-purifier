# composer-purifier

composer-purifier builds Composer projects with Nix. Nix reads the
downloads that `composer install` needs from `composer.lock`, and a second
lockfile, `composer-purifier.lock.json`, holds the hashes that
`composer.lock` lacks. Nix fetches those downloads, and `composer install`
runs in the Nix sandbox with the network disabled. composer-purifier meets the
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

`lock` keeps the resolution that `composer.lock` records. When
`composer.lock` is missing, `lock` stops and names `composer update`. When
`composer.json` has changed since `composer.lock` was written, `lock` stops
and names `composer update --lock`. `composer.lock` is written by
Composer, or by `composer-purifier update`.

Then build the project from the same directory, with no Nix file added to
it. `<name>` is the `name` of `composer.json` with `/` replaced by `-`, such
as `my-vendor-my-app`:

```zsh
nix build --impure --expr '
  let
    purifier = builtins.getFlake "github:nix-purifiers/composer-purifier";
    pkgs = import purifier.inputs.nixpkgs {
      system = builtins.currentSystem;
      overlays = [ purifier.overlays.default ];
    };
  in
  (pkgs.composer-purifier.buildComposerProject { src = ./.; }).packages.my-app'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

The flake's overlay adds one attribute to the package set, the scope
`composer-purifier`. The scope holds the builder `buildComposerProject`
beside the `composer-purifier` command. A flake that packages the project
applies the overlay and calls the builder. It can live in the repository of
the project or in another one:

```nix
{
  inputs.composer-purifier.url = "github:nix-purifiers/composer-purifier";
  inputs.nixpkgs.follows = "composer-purifier/nixpkgs";

  outputs = { nixpkgs, composer-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system}.extend composer-purifier.overlays.default;
      app = pkgs.composer-purifier.buildComposerProject { src = ./.; };
    in
    {
      packages.${system} = app.packages;
      checks.${system}.tests = app.tests;
    };
}
```

`composer-purifier.buildComposerProject.override` replaces the packages that
the builder takes, and `composer-purifier.overrideScope` replaces what
everything in the scope shares.

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
`src`, `fetchers`, `lockFile`, `composerLock`, `php`, `dev`, `noScripts`,
`composerFlags`, `pathRepositories` and `srcFilter`.
`lib.composer-purifier.readLock { src; }` gives the lock in memory of the
contract: the download entries, the outputs, and the problems of the
lockfiles, each naming the command that fixes it.

We recommend committing both lockfiles, `composer.lock` and
`composer-purifier.lock.json`, to the repository of the project. The
builder and the commands look for them there by default.

A project can instead keep its build external. The flake that calls the
builder keeps the purifier lockfile outside the repository and passes it
as `lockFile`. It can also keep its own copy of `composer.lock` and pass it
as `composerLock`, which the build uses in place of the copy in `src`. An
external build suits a project whose committed `composer.lock` is missing,
out of date or written by another version of Composer. Every command takes
`--lockfile <path>` and `--tool-lockfile <path>`, or reads the paths from
the environment variables `COMPOSER_PURIFIER_LOCKFILE` and
`COMPOSER_PURIFIER_TOOL_LOCKFILE`. With a tool lockfile, `update` writes
`composer.lock` there and leaves the copy in the repository as it is, and
`lock` starts from the copy in the repository when the outside file does
not exist yet. A dev shell that sets both variables to the paths it passes
to the builder needs no flags.

## Development loop

`nix develop github:nix-purifiers/composer-purifier` gives PHP, the
`composer-purifier` command, its `composer`, and phpactor. The
`composer-purifier` command runs Composer as a PHP library and is not a
Composer plugin, because `lock` runs before the `vendor` directory exists.
The loop is Composer's own:

1. `composer-purifier prefetch` fetches what the lockfile names into the
   Nix store (see [Working offline](#working-offline)).
2. `composer install` installs the project from those downloads, offline,
   with a PHP that has the extensions the project requires.
3. The project runs as usual: its `bin` scripts with `php`, its tests with
   `composer test`.
4. `composer-purifier update [<package>...]` updates both lockfiles in one
   run: it runs `composer update --no-install` on the PHP that the project
   requires, for every package or only the named ones, and then
   `composer-purifier lock`. After a `composer require` or a plain
   `composer update`, `composer-purifier lock` alone records the new
   downloads and keeps the resolution of `composer.lock` as it is. Either
   way, the hashes it already has are reused, and `composer-purifier
   prefetch` then fetches the new downloads.

The next `composer install` after a change to `composer.lock` stops until
the lockfile and the prefetch catch up, and says which command to run.

## Working offline

`composer-purifier prefetch` builds three things with `nix-build`: the
Composer cache of the lockfile, Composer on the PHP that the project
requires with its `require-dev` packages, and the `composer.lock` of an
offline install. It keeps them alive with garbage-collector roots in
`.composer-purifier/`, beside the lockfile, which belongs in `.gitignore`.
The `require-dev` packages are part of the prefetch, so the tests run
offline too.

After a prefetch, the `composer` of this flake reads `.composer-purifier/`
for `composer install`, and runs it with the network disabled. Every other
subcommand is plain Composer. A package that the lockfile does not name
fails to install offline, because the network is disabled.

## Editor

PHP editors and language servers, such as phpactor and Intelephense, read
the project's `vendor` directory. A Composer dist holds the full source of
its package, so `composer install` after a prefetch gives the editor the
full source of every package. The development shell has phpactor.

## Troubleshooting

The Nix build, `composer-purifier prefetch` and the offline
`composer install` check the lockfile before they use it. Each failure says
what is wrong and which command fixes it:

| Mistake | Message |
| --- | --- |
| A command such as `composer require` added a download to `composer.lock`, and `lock` has not run since. | `composer-purifier.lock.json has no hash for the dist of <package> at <URL>, which composer.lock has. Run composer-purifier lock.` A checkout reads `the git checkout of <package> at <URL>#<reference>` in place of the dist. |
| The lockfile changed after the last prefetch. | `<lockfile> changed after the last prefetch. Run composer-purifier prefetch.` |
| Someone edited the lockfile by hand, a hash included. | `… was edited after composer-purifier lock wrote it: its content does not match its contentHash. Run composer-purifier lock --force to write it again.` |
| The lockfile is not valid JSON, or its `dists` or `sources` field is not a map of hashes. | The message names the problem and ends with `Run composer-purifier lock --force …` |
| Another version of composer-purifier wrote the lockfile. | `… has lock format version <n>; this composer-purifier reads version 4. Run composer-purifier lock --force …` |
| A download no longer matches its locked hash | Nix rejects it with `hash mismatch in fixed-output derivation`, naming both hashes |
| `composer.json` changed and `composer update` has not run | `lock` stops with `composer.lock is out of date with composer.json. Run composer update --lock first.` |

The lockfile, format 4, holds only what `composer.lock` lacks. `dists`
maps the dist URL of each package whose `shasum` is empty to the SHA-256
of the file. `sources` maps `<URL>#<reference>` of each package that has
only a version-control source to the hash of its checkout. A dist with a
`shasum` needs no entry, since Nix checks the SHA-1 of `composer.lock`.
Nix derives every URL, mirror and cache path from `composer.lock`. The
lockfile also holds `contentHash`, the SHA-256 of its other fields, so an
edit by hand fails before any download.

## Supported language repositories

Every kind of package source that `composer.lock` can hold builds, except
Perforce. The sources are Packagist and other Composer repositories with
dists, `package` repositories that name an archive URL, version-control
repositories, and `path` repositories.

- A dist, the archive that Packagist and most repositories serve, is
  fetched from its URL and the mirrors of its repository, as
  `composer.lock` gives them. This covers `zip`,
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
  with the network. The `simple-phpunit` of symfony/phpunit-bridge installs
  PHPUnit with Composer the first time it runs, and that download is not
  part of `composer.lock`. A project whose tests run offline requires
  `phpunit/phpunit` in `require-dev` instead.
- The hash of a GitHub dist is the hash of the zip archive that GitHub
  generates. If GitHub changes how it generates archives, the fetch fails
  with a hash mismatch, and `lock --force` records the new hashes.
- The offline installs set `COMPOSER_POLICY=0`, which turns off the
  install-time policy of Composer 2.10. That policy fetches malware and
  advisory lists from the package repositories, which an offline install
  cannot reach. `lock` runs the same check online, with `composer audit`.

## Examples

### Composer itself

[composer/composer](https://github.com/composer/composer) is built the way
the Quickstart builds any project. Check out the release you want, lock it,
and build its `composer` executable from the checkout:

```zsh
git clone --branch 2.10.3 https://github.com/composer/composer
cd composer
nix run github:nix-purifiers/composer-purifier -- lock
nix build --impure --expr '
  let
    purifier = builtins.getFlake "github:nix-purifiers/composer-purifier";
    pkgs = import purifier.inputs.nixpkgs {
      system = builtins.currentSystem;
      overlays = [ purifier.overlays.default ];
    };
  in
  (pkgs.composer-purifier.buildComposerProject { src = ./.; }).packages.composer'
./result/bin/composer --version
```

To move to a newer release, check out its tag and run the same commands
again.

## Credits

composer-purifier follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier), formerly
sbt-nix-backend: the build tool keeps planning the build, a lock run
records every download by URL and hash, and Nix builds from that record in
its sandbox. sbt-nix-backend took its model from nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo). The downloads are the
entries of the shared [purifier](https://github.com/nix-purifiers/purifier)
library, which fetches them and lays them out.
