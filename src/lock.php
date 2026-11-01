<?php
// SPDX-License-Identifier: MIT
//
// `composer-purifier lock`: writes composer-purifier.lock.json next to
// composer.lock, for the Composer project in the current directory.
//
//   php lock.php <Composer's vendor/autoload.php> [--force] [--lockfile <path>]
//
// --lockfile writes the lockfile at <path> rather than next to composer.lock,
// for a project whose source does not hold it.
//
// The lockfile names every file that `composer install` downloads for the
// packages of composer.lock, with the path of the file in Composer's cache
// directory and its SHA-256 hash. Composer finds a locked dist in its cache
// at files/<package>/<sha1 of the URL>.<dist type> (FileDownloader::download),
// so a cache built from these entries lets `composer install` run offline.
// `packages` maps every package of composer.lock to the path of its entry,
// or to null for a package of a path repository. `contentHash` is the hash
// of everything else in the file (contentHash in functions.php), so that an
// edit by hand fails the build and `composer-purifier prefetch`.
//
// The script uses Composer as a library: it reads the locked packages the
// way `composer install` does, computes each download URL with Composer's
// own Url::updateDistReference, and downloads through Composer's
// HttpDownloader, so the credentials of auth.json apply.
//
// A package that composer.lock gives only a version-control source (git,
// hg, svn or fossil) gets a checkout entry instead: the repository URL, the
// locked revision, and the hash of the checkout that the nixpkgs fetcher of
// that kind makes. The command that COMPOSER_PURIFIER_HASH_CHECKOUT names
// computes the hash; the composer-purifier package sets it to a script that
// runs the fetcher itself. The Nix side installs such a package from its
// checkout as a path dist (nix/lib/offline-lock.nix).
//
// A lockfile made from the same composer.lock is left as it is, unless
// --force is given. Otherwise the hashes of downloads the old lockfile
// already names are kept, and only new downloads are fetched.

declare(strict_types=1);

namespace ComposerPurifier;

use Composer\Factory;
use Composer\IO\ConsoleIO;
use Composer\Package\AliasPackage;
use Symfony\Component\Console\Helper\HelperSet;
use Symfony\Component\Console\Helper\QuestionHelper;
use Symfony\Component\Console\Input\ArgvInput;
use Symfony\Component\Console\Output\ConsoleOutput;

require __DIR__ . '/functions.php';

$usage = "usage: lock.php <Composer vendor/autoload.php> [--force] [--lockfile <path>]\n";
$autoload = $argv[1] ?? null;
$force = false;
$lockFileOption = null;
$arguments = array_slice($argv, 2);
while ($arguments !== []) {
    $argument = array_shift($arguments);
    if ($argument === '--force') {
        $force = true;
    } elseif ($argument === '--lockfile' && $arguments !== []) {
        $lockFileOption = array_shift($arguments);
    } else {
        $autoload = null;
        break;
    }
}
if ($autoload === null) {
    fwrite(STDERR, $usage);
    exit(2);
}
require $autoload;

try {
    $io = new ConsoleIO(new ArgvInput([]), new ConsoleOutput(), new HelperSet([new QuestionHelper()]));

    // Plugins stay off: the lock step runs before `vendor` exists, and the
    // downloads of composer.lock do not depend on them.
    $composer = Factory::create($io, null, true);
    $composerLockFile = Factory::getLockFile(Factory::getComposerFile());
    $locker = $composer->getLocker();
    if (!$locker->isLocked()) {
        throw new PurifierException('there is no composer.lock. Run `composer update` first.');
    }
    if (!$locker->isFresh()) {
        throw new PurifierException('composer.lock is out of date with composer.json. Run `composer update --lock` first.');
    }

    $lockFile = $lockFileOption ?? dirname($composerLockFile) . '/' . LOCK_FILE;
    $composerLockHash = sriSha256($composerLockFile);
    $old = readOldLock($lockFile);
    if (!$force && $old['composerLock'] === $composerLockHash) {
        $io->writeError(LOCK_FILE . ' is up to date with composer.lock.');
        exit(0);
    }

    $config = $composer->getConfig();
    $loop = $composer->getLoop();
    $downloader = $loop->getHttpDownloader();
    $downloadDir = sys_get_temp_dir() . '/composer-purifier-' . bin2hex(random_bytes(8));
    mkdir($downloadDir, 0700, true);

    $artifacts = [];
    $packages = [];
    $promises = [];
    foreach ($locker->getLockedRepository(true)->getPackages() as $package) {
        if ($package instanceof AliasPackage) {
            continue;
        }
        $name = $package->getPrettyName();
        $type = $package->getDistType();
        if ($type === null) {
            $kind = (string) $package->getSourceType();
            $sourceUrl = $package->getSourceUrl();
            $reference = $package->getSourceReference();
            if ($sourceUrl === null || $reference === null) {
                throw new PurifierException("{$name} has neither a dist nor a source with a URL and a reference in composer.lock.");
            }
            $checkout = checkoutOf($name, $kind, $sourceUrl, $reference);
            $path = $kind . '/' . $package->getName();
            $key = checkoutKey($kind, $checkout['url'], $checkout['rev']);
            if (!isset($old['hashes'][$key])) {
                $io->writeError("Fetching {$name} ({$package->getFullPrettyVersion()}) from {$sourceUrl}");
            }
            $artifacts[$path] = [
                'path' => $path,
                $kind => $checkout,
                'hash' => $old['hashes'][$key] ?? hashCheckout($kind, $checkout),
            ];
            $packages[$name] = $path;
            continue;
        }
        // A path package is installed from the project's own files.
        if ($type === 'path') {
            $packages[$name] = null;
            continue;
        }
        if (!in_array($type, CACHED_DIST_TYPES, true)) {
            throw new PurifierException("{$name} has a dist of type {$type}, which Composer does not keep in its files cache.");
        }

        $urls = distUrls($config, $package);
        $url = $urls[0];
        $mirrors = array_slice($urls, 1);
        $path = cachePathFor($package->getName(), $url, $type);
        $packages[$name] = $path;
        if (isset($old['hashes'][$url])) {
            $artifacts[$path] = ['path' => $path, 'url' => $url, 'mirrors' => $mirrors, 'hash' => $old['hashes'][$url]];
            continue;
        }

        $target = $downloadDir . '/' . count($promises);
        $io->writeError("Downloading {$name} ({$package->getFullPrettyVersion()})");
        $promises[] = $downloader->addCopy($url, $target, $package->getTransportOptions())->then(
            function () use (&$artifacts, $package, $name, $url, $mirrors, $path, $target): void {
                $sha1 = $package->getDistSha1Checksum();
                if ($sha1 !== null && $sha1 !== '' && hash_file('sha1', $target) !== $sha1) {
                    throw new PurifierException("the dist of {$name} from {$url} does not match the shasum in composer.lock.");
                }
                $artifacts[$path] = ['path' => $path, 'url' => $url, 'mirrors' => $mirrors, 'hash' => sriSha256($target)];
                unlink($target);
            }
        );
    }
    $loop->wait($promises);
    rmdir($downloadDir);

    ksort($artifacts);
    ksort($packages);
    $lock = [
        'version' => FORMAT_VERSION,
        'composerLock' => $composerLockHash,
        // An object even when it is empty, so that Nix reads an attribute set.
        'packages' => (object) $packages,
        'artifacts' => array_values($artifacts),
    ];
    $lock['contentHash'] = contentHash($lock);
    file_put_contents($lockFile, json_encode($lock, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    $io->writeError('Wrote ' . LOCK_FILE . ' with ' . count($artifacts) . ' downloads.');
} catch (PurifierException $e) {
    fwrite(STDERR, "composer-purifier: {$e->getMessage()}\n");
    exit(1);
}
