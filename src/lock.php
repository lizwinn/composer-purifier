<?php
// SPDX-License-Identifier: MIT
//
// `composer-purifier lock`: writes composer-purifier.lock.json next to
// composer.lock, for the Composer project in the current directory.
//
//   php lock.php <Composer's vendor/autoload.php> [--force]
//
// The lockfile names every file that `composer install` downloads for the
// packages of composer.lock, with the path of the file in Composer's cache
// directory and its SHA-256 hash. Composer finds a locked dist in its cache
// at files/<package>/<sha1 of the URL>.<dist type> (FileDownloader::download),
// so a cache built from these entries lets `composer install` run offline.
//
// The script uses Composer as a library: it reads the locked packages the
// way `composer install` does, computes each download URL with Composer's
// own Url::updateDistReference, and downloads through Composer's
// HttpDownloader, so the credentials of auth.json apply.
//
// A lockfile made from the same composer.lock is left as it is, unless
// --force is given. Otherwise the hashes of URLs the old lockfile already
// names are kept, and only new URLs are downloaded.

declare(strict_types=1);

use Composer\Factory;
use Composer\IO\ConsoleIO;
use Composer\IO\IOInterface;
use Composer\Package\AliasPackage;
use Composer\Package\PackageInterface;
use Composer\Util\Url;
use Symfony\Component\Console\Helper\HelperSet;
use Symfony\Component\Console\Helper\QuestionHelper;
use Symfony\Component\Console\Input\ArgvInput;
use Symfony\Component\Console\Output\ConsoleOutput;

// The format version of the lockfile. nix/lib/lock-version.nix holds the
// same number.
const FORMAT_VERSION = 1;

const LOCK_FILE = 'composer-purifier.lock.json';

// The dist types whose downloader keeps the downloaded file in Composer's
// files cache (the downloaders that extend FileDownloader).
const CACHED_DIST_TYPES = ['zip', 'tar', 'gzip', 'xz', 'rar', 'phar', 'file'];

// The characters Composer keeps in a files-cache path; Cache::copyTo
// replaces every other character with "-".
const CACHE_PATH_ALLOWLIST = 'a-z0-9_./';

function fail(string $message): never
{
    fwrite(STDERR, "composer-purifier: {$message}\n");
    exit(1);
}

function sriSha256(string $file): string
{
    return 'sha256-' . base64_encode(hash_file('sha256', $file, true));
}

/**
 * The hashes of an existing lockfile, by URL. An unreadable lockfile or one
 * of another format version holds none.
 *
 * @return array{composerLock: ?string, hashes: array<string, string>}
 */
function readOldLock(string $file): array
{
    $none = ['composerLock' => null, 'hashes' => []];
    if (!is_file($file)) {
        return $none;
    }
    $lock = json_decode((string) file_get_contents($file), true);
    if (!is_array($lock) || ($lock['version'] ?? null) !== FORMAT_VERSION) {
        return $none;
    }
    $hashes = [];
    foreach ($lock['artifacts'] ?? [] as $artifact) {
        $hashes[$artifact['url']] = $artifact['hash'];
    }

    return ['composerLock' => $lock['composerLock'] ?? null, 'hashes' => $hashes];
}

/**
 * The URL that `composer install` downloads the dist of $package from,
 * as FileDownloader::processUrl computes it.
 */
function distUrl(\Composer\Config $config, PackageInterface $package): string
{
    $url = $package->getDistUrls()[0];
    $reference = $package->getDistReference();
    if ($reference !== null) {
        $url = Url::updateDistReference($config, $url, $reference);
    }

    return $url;
}

/**
 * The path of a dist in Composer's cache directory, as FileDownloader
 * names it and Cache::copyTo sanitizes it.
 */
function cachePath(PackageInterface $package, string $url): string
{
    $key = $package->getName() . '/' . hash('sha1', $url) . '.' . $package->getDistType();

    return 'files/' . preg_replace('{[^' . CACHE_PATH_ALLOWLIST . ']}i', '-', $key);
}

$autoload = $argv[1] ?? fail('usage: lock.php <Composer vendor/autoload.php> [--force]');
$force = in_array('--force', array_slice($argv, 2), true);
require $autoload;

$io = new ConsoleIO(new ArgvInput([]), new ConsoleOutput(), new HelperSet([new QuestionHelper()]));

// Plugins stay off: the lock step runs before `vendor` exists, and the
// downloads of composer.lock do not depend on them.
$composer = Factory::create($io, null, true);
$composerLockFile = Factory::getLockFile(Factory::getComposerFile());
$locker = $composer->getLocker();
if (!$locker->isLocked()) {
    fail('there is no composer.lock. Run `composer update` first.');
}
if (!$locker->isFresh()) {
    fail('composer.lock is out of date with composer.json. Run `composer update --lock` first.');
}

$lockFile = dirname($composerLockFile) . '/' . LOCK_FILE;
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
$promises = [];
foreach ($locker->getLockedRepository(true)->getPackages() as $package) {
    if ($package instanceof AliasPackage) {
        continue;
    }
    $name = $package->getPrettyName();
    $type = $package->getDistType();
    if ($type === null) {
        fail("{$name} has no dist in composer.lock, only a {$package->getSourceType()} source. composer-purifier locks dists only.");
    }
    // A path package is installed from the project's own files.
    if ($type === 'path') {
        continue;
    }
    if (!in_array($type, CACHED_DIST_TYPES, true)) {
        fail("{$name} has a dist of type {$type}, which Composer does not keep in its files cache.");
    }

    $url = distUrl($config, $package);
    $path = cachePath($package, $url);
    if (isset($old['hashes'][$url])) {
        $artifacts[$path] = ['path' => $path, 'url' => $url, 'hash' => $old['hashes'][$url]];
        continue;
    }

    $target = $downloadDir . '/' . count($promises);
    $io->writeError("Downloading {$name} ({$package->getFullPrettyVersion()})");
    $promises[] = $downloader->addCopy($url, $target, $package->getTransportOptions())->then(
        function () use (&$artifacts, $package, $name, $url, $path, $target): void {
            $sha1 = $package->getDistSha1Checksum();
            if ($sha1 !== null && $sha1 !== '' && hash_file('sha1', $target) !== $sha1) {
                fail("the dist of {$name} from {$url} does not match the shasum in composer.lock.");
            }
            $artifacts[$path] = ['path' => $path, 'url' => $url, 'hash' => sriSha256($target)];
            unlink($target);
        }
    );
}
$loop->wait($promises);
rmdir($downloadDir);

ksort($artifacts);
$lock = [
    'version' => FORMAT_VERSION,
    'composerLock' => $composerLockHash,
    'artifacts' => array_values($artifacts),
];
file_put_contents($lockFile, json_encode($lock, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
$io->writeError('Wrote ' . LOCK_FILE . ' with ' . count($artifacts) . ' files.', true, IOInterface::NORMAL);
