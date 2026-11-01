<?php
// SPDX-License-Identifier: MIT
//
// The functions of `composer-purifier lock` (lock.php) and of the lockfile
// check of `composer-purifier install` (check.php). They throw
// PurifierException for every error that the person running the command
// can fix; the scripts print its message and exit. tests/unit/functions.php
// tests them.

declare(strict_types=1);

namespace ComposerPurifier;

use Composer\Config;
use Composer\Package\PackageInterface;
use Composer\Util\Url;

// The format version of the lockfile. nix/lib/lock-version.nix holds the
// same number.
const FORMAT_VERSION = 3;

const LOCK_FILE = 'composer-purifier.lock.json';

// The dist types whose downloader keeps the downloaded file in Composer's
// files cache (the downloaders that extend FileDownloader).
const CACHED_DIST_TYPES = ['zip', 'tar', 'gzip', 'xz', 'rar', 'phar', 'file'];

// The characters Composer keeps in a files-cache path; Cache::copyTo
// replaces every other character with "-".
const CACHE_PATH_ALLOWLIST = 'a-z0-9_./';

// The version-control kinds that a checkout entry can hold, as Composer
// names its source types.
const VCS_KINDS = ['git', 'hg', 'svn', 'fossil'];

final class PurifierException extends \RuntimeException
{
}

function sriSha256(string $file): string
{
    return 'sha256-' . base64_encode(hash_file('sha256', $file, true));
}

/**
 * $value as JSON in the form that Nix's builtins.toJSON writes: object
 * keys sorted, no whitespace, slashes and non-ASCII characters as they are.
 * An object is a stdClass or an array with string keys; an array with keys
 * 0, 1, … is a list, the empty array included.
 */
function canonicalJson(mixed $value): string
{
    if ($value instanceof \stdClass) {
        $value = get_object_vars($value);
        $isObject = true;
    } else {
        $isObject = is_array($value) && !array_is_list($value);
    }
    if ($isObject) {
        ksort($value, SORT_STRING);
        $members = [];
        foreach ($value as $key => $member) {
            $members[] = json_encode((string) $key, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . ':' . canonicalJson($member);
        }

        return '{' . implode(',', $members) . '}';
    }
    if (is_array($value)) {
        return '[' . implode(',', array_map(__NAMESPACE__ . '\canonicalJson', $value)) . ']';
    }

    return json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
}

/**
 * The hash of the content of a lockfile: the SRI SHA-256 of the canonical
 * JSON of every field but `contentHash` itself. nix/lib/lock.nix computes
 * the same hash with builtins.toJSON.
 *
 * @param array<string, mixed>|\stdClass $lock
 */
function contentHash(array|\stdClass $lock): string
{
    $fields = $lock instanceof \stdClass ? get_object_vars($lock) : $lock;
    unset($fields['contentHash']);

    return 'sha256-' . base64_encode(hash('sha256', canonicalJson((object) $fields), true));
}

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
                throw new PurifierException("{$name} has the svn reference {$reference}, which names no revision number.");
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
        case 'perforce':
            throw new PurifierException("{$name} has only a perforce source. A Perforce depot has no anonymous protocol that a fetcher could use, needs a server and credentials, and nixpkgs has no fetcher for it.");
    }
    throw new PurifierException("{$name} has neither a dist nor a git, hg, svn or fossil source in composer.lock.");
}

/**
 * The URLs that `composer install` tries for the dist of $package, in
 * order, as FileDownloader::processUrl computes them: the dist URL and the
 * mirrors of its repository. FileDownloader looks for the dist in its cache
 * under the first of them.
 *
 * @return non-empty-list<string>
 */
function distUrls(Config $config, PackageInterface $package): array
{
    $reference = $package->getDistReference();

    return array_map(
        static fn (string $url): string => $reference === null ? $url : Url::updateDistReference($config, $url, $reference),
        $package->getDistUrls()
    );
}

/**
 * The path of a dist in Composer's cache directory, as FileDownloader
 * names it (<package>/<sha1 of the URL>.<dist type>) and Cache::copyTo
 * sanitizes it.
 */
function cachePathFor(string $name, string $url, string $distType): string
{
    $key = $name . '/' . hash('sha1', $url) . '.' . $distType;

    return 'files/' . preg_replace('{[^' . CACHE_PATH_ALLOWLIST . ']}i', '-', $key);
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
        if ($key !== null && isset($artifact['hash'])) {
            $hashes[$key] = $artifact['hash'];
        }
    }

    return ['composerLock' => $lock['composerLock'] ?? null, 'hashes' => $hashes];
}

/**
 * The hash of a checkout, from the command that
 * COMPOSER_PURIFIER_HASH_CHECKOUT names. The command takes the kind and the
 * checkout as JSON, and prints the SRI hash of the checkout.
 *
 * @param array<string, mixed> $checkout
 */
function hashCheckout(string $kind, array $checkout): string
{
    $command = getenv('COMPOSER_PURIFIER_HASH_CHECKOUT');
    if ($command === false || $command === '') {
        throw new PurifierException('COMPOSER_PURIFIER_HASH_CHECKOUT names no command to hash checkouts with. Run lock through the composer-purifier command.');
    }
    $process = proc_open(
        [$command, $kind, json_encode($checkout, JSON_UNESCAPED_SLASHES)],
        [1 => ['pipe', 'w']],
        $pipes
    );
    if (!is_resource($process)) {
        throw new PurifierException("could not run {$command}.");
    }
    $output = trim((string) stream_get_contents($pipes[1]));
    fclose($pipes[1]);
    if (proc_close($process) !== 0 || !str_starts_with($output, 'sha256-')) {
        throw new PurifierException("could not hash the {$kind} checkout of {$checkout['url']} at {$checkout['rev']}.");
    }

    return $output;
}

/**
 * The names of the packages of composer.lock, require-dev included.
 *
 * @param array<string, mixed> $composerLock
 *
 * @return list<string>
 */
function lockedPackageNames(array $composerLock): array
{
    $names = [];
    foreach (array_merge($composerLock['packages'] ?? [], $composerLock['packages-dev'] ?? []) as $package) {
        $names[] = (string) $package['name'];
    }
    sort($names);

    return $names;
}

/**
 * Checks that the lockfile $lockText is one this version reads, that it was
 * made from the composer.lock whose text is $composerLockText, and that it
 * names an entry for every package of that composer.lock. Every failure
 * names the command that fixes it.
 */
function checkLock(string $lockText, string $composerLockText): void
{
    $relock = 'Run `composer-purifier lock --force` to write it again.';
    try {
        $lock = json_decode($lockText, true, 512, JSON_THROW_ON_ERROR);
    } catch (\JsonException $e) {
        throw new PurifierException(LOCK_FILE . " is not valid JSON ({$e->getMessage()}). {$relock}");
    }
    if (!is_array($lock)) {
        throw new PurifierException(LOCK_FILE . " holds no JSON object. {$relock}");
    }
    if (($lock['version'] ?? null) !== FORMAT_VERSION) {
        $version = json_encode($lock['version'] ?? null);
        throw new PurifierException(LOCK_FILE . " has lock format version {$version}; this composer-purifier reads version " . FORMAT_VERSION . ". {$relock}");
    }
    foreach (['composerLock' => 'is_string', 'artifacts' => 'is_array', 'packages' => 'is_array'] as $field => $test) {
        if (!isset($lock[$field]) || !$test($lock[$field])) {
            throw new PurifierException(LOCK_FILE . " has no valid `{$field}` field. {$relock}");
        }
    }
    $paths = [];
    foreach ($lock['artifacts'] as $index => $artifact) {
        if (!is_array($artifact) || !isset($artifact['path'], $artifact['hash'])) {
            throw new PurifierException(LOCK_FILE . " has an entry without a path or a hash, at index {$index}. {$relock}");
        }
        $paths[$artifact['path']] = true;
    }

    // Decoded into objects, so that an empty object stays one.
    $lockObject = json_decode($lockText, false);
    if (($lock['contentHash'] ?? null) !== contentHash($lockObject)) {
        throw new PurifierException(LOCK_FILE . " was edited after `composer-purifier lock` wrote it: its content does not match its contentHash. {$relock}");
    }

    $hash = 'sha256-' . base64_encode(hash('sha256', $composerLockText, true));
    if ($lock['composerLock'] !== $hash) {
        throw new PurifierException('composer.lock changed after ' . LOCK_FILE . ' was written. Run `composer-purifier lock`.');
    }

    $composerLock = json_decode($composerLockText, true);
    if (!is_array($composerLock)) {
        throw new PurifierException('composer.lock is not valid JSON. Run `composer update --lock`.');
    }
    $named = array_keys($lock['packages']);
    sort($named);
    $locked = lockedPackageNames($composerLock);
    $missing = array_diff($locked, $named);
    if ($missing !== []) {
        throw new PurifierException(LOCK_FILE . ' names no download for ' . implode(', ', $missing) . ", which composer.lock has. {$relock}");
    }
    $extra = array_diff($named, $locked);
    if ($extra !== []) {
        throw new PurifierException(LOCK_FILE . ' names ' . implode(', ', $extra) . ", which composer.lock does not have. {$relock}");
    }
    foreach ($lock['packages'] as $name => $path) {
        if ($path !== null && !isset($paths[$path])) {
            throw new PurifierException(LOCK_FILE . " names {$path} for {$name}, but has no entry at that path. {$relock}");
        }
    }
}
