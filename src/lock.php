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
// A package that composer.lock gives only a version-control source (git,
// hg, svn or fossil) gets a checkout entry instead: the repository URL, the
// locked revision, and the hash of the checkout that the nixpkgs fetcher of
// that kind makes. The command that COMPOSER_PURIFIER_PREFETCH names
// computes the hash; the composer-purifier package sets it to a script that
// runs the fetcher itself. The Nix side installs such a package from its
// checkout as a path dist (nix/lib/offline-lock.nix).
//
// A lockfile made from the same composer.lock is left as it is, unless
// --force is given. Otherwise the hashes of downloads the old lockfile
// already names are kept, and only new downloads are fetched.

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

// The version-control kinds that a checkout entry can hold, as Composer
// names its source types.
const VCS_KINDS = ['git', 'hg', 'svn', 'fossil'];

/**
 * The key of a download in readOldLock: the URL of a file, or the kind,
 * URL and revision of a checkout.
 */
function checkoutKey(string $kind, string $url, string $rev): string
{
    return $kind . '#' . $url . '#' . $rev;
}

/**
 * The HTTPS URL of a git repository that $url names over SSH, as
 * git@host:owner/repo.git or ssh://git@host/owner/repo.git. Any other URL
 * stays as it is.
 */
function httpsGitUrl(string $url): string
{
    // ssh://[user@]host[:port]/path
    if (preg_match('{^ssh://(?:[^@/]+@)?([^:/]+)(?::\d+)?/(.+)$}', $url, $match)) {
        return 'https://' . $match[1] . '/' . $match[2];
    }
    // user@host:path, the scp-like syntax of git
    if (!str_contains($url, '://') && preg_match('{^[^@/]+@([^:/]+):(.+)$}', $url, $match)) {
        return 'https://' . $match[1] . '/' . ltrim($match[2], '/');
    }

    return $url;
}

/**
 * The checkout of a source as the lockfile records it, under the key of
 * its kind. Each holds what the nixpkgs fetcher of that kind takes, with
 * the options that match what Composer's downloader of that kind installs.
 *
 * @return array<string, mixed>
 */
function checkoutOf(string $name, string $kind, string $url, string $reference): array
{
    switch ($kind) {
        case 'git':
            // GitDownloader never runs `git submodule`. The Nix sandbox has
            // no SSH keys, so an SSH URL is recorded as the HTTPS URL of the
            // same repository; a private repository then needs a fetchgit
            // with credentials (the `vcsFetchers` of buildComposerProject).
            // The install takes the checkout as a path dist, which needs no
            // .git directory, so there is no commit object to record.
            return [
                'url' => httpsGitUrl($url),
                'rev' => $reference,
                'submodules' => false,
                'leaveDotGit' => false,
                'commitObject' => null,
            ];
        case 'hg':
            // HgDownloader runs `hg update`, which checks out subrepositories.
            return ['url' => $url, 'rev' => $reference, 'subrepos' => true];
        case 'svn':
            // SvnDownloader checks out <url>/<reference>, and a reference is
            // a path in the repository with a peg revision: trunk/@1234.
            // Its plain `svn co` follows externals and expands keywords.
            if (!preg_match('{^(.*)@(\d+)$}', $reference, $match)) {
                fail("{$name} has the svn reference {$reference}, which names no revision number.");
            }
            $path = trim($match[1], '/');

            return [
                'url' => rtrim($url, '/') . ($path === '' ? '' : '/' . $path),
                'rev' => $match[2],
                'ignoreExternals' => false,
                'ignoreKeywords' => false,
            ];
        case 'fossil':
            return ['url' => $url, 'rev' => $reference];
    }
    fail("{$name} has a source of unknown kind {$kind}.");
}

/**
 * The hashes of an existing lockfile, by download key. An unreadable
 * lockfile or one of another format version holds none.
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
        $key = $artifact['url'] ?? null;
        foreach (VCS_KINDS as $kind) {
            if (isset($artifact[$kind])) {
                $key = checkoutKey($kind, $artifact[$kind]['url'], $artifact[$kind]['rev']);
            }
        }
        if ($key !== null) {
            $hashes[$key] = $artifact['hash'];
        }
    }

    return ['composerLock' => $lock['composerLock'] ?? null, 'hashes' => $hashes];
}

/**
 * The hash of a checkout, from the command that COMPOSER_PURIFIER_PREFETCH
 * names. The command takes the kind and the checkout as JSON, and prints
 * the SRI hash of the checkout.
 *
 * @param array<string, mixed> $checkout
 */
function prefetch(string $kind, array $checkout): string
{
    $command = getenv('COMPOSER_PURIFIER_PREFETCH');
    if ($command === false || $command === '') {
        fail('COMPOSER_PURIFIER_PREFETCH names no command to hash checkouts with. Run lock through the composer-purifier command.');
    }
    $process = proc_open(
        [$command, $kind, json_encode($checkout, JSON_UNESCAPED_SLASHES)],
        [1 => ['pipe', 'w']],
        $pipes
    );
    if (!is_resource($process)) {
        fail("could not run {$command}.");
    }
    $output = trim((string) stream_get_contents($pipes[1]));
    fclose($pipes[1]);
    if (proc_close($process) !== 0 || !str_starts_with($output, 'sha256-')) {
        fail("could not hash the {$kind} checkout of {$checkout['url']} at {$checkout['rev']}.");
    }

    return $output;
}

/**
 * The URLs that `composer install` tries for the dist of $package, in
 * order, as FileDownloader::processUrl computes them: the dist URL and the
 * mirrors of its repository. FileDownloader looks for the dist in its cache
 * under the first of them.
 *
 * @return non-empty-list<string>
 */
function distUrls(\Composer\Config $config, PackageInterface $package): array
{
    $reference = $package->getDistReference();

    return array_map(
        static fn (string $url): string => $reference === null ? $url : Url::updateDistReference($config, $url, $reference),
        $package->getDistUrls()
    );
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
        $kind = (string) $package->getSourceType();
        $sourceUrl = $package->getSourceUrl();
        $reference = $package->getSourceReference();
        if ($kind === 'perforce') {
            fail("{$name} has only a perforce source. A Perforce depot has no anonymous protocol that a fetcher could use, needs a server and credentials, and nixpkgs has no fetcher for it.");
        }
        if (!in_array($kind, VCS_KINDS, true) || $sourceUrl === null || $reference === null) {
            fail("{$name} has neither a dist nor a git, hg, svn or fossil source in composer.lock.");
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
            'hash' => $old['hashes'][$key] ?? prefetch($kind, $checkout),
        ];
        continue;
    }
    // A path package is installed from the project's own files.
    if ($type === 'path') {
        continue;
    }
    if (!in_array($type, CACHED_DIST_TYPES, true)) {
        fail("{$name} has a dist of type {$type}, which Composer does not keep in its files cache.");
    }

    $urls = distUrls($config, $package);
    $url = $urls[0];
    $mirrors = array_slice($urls, 1);
    $path = cachePath($package, $url);
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
                fail("the dist of {$name} from {$url} does not match the shasum in composer.lock.");
            }
            $artifacts[$path] = ['path' => $path, 'url' => $url, 'mirrors' => $mirrors, 'hash' => sriSha256($target)];
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
