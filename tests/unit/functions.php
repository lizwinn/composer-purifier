<?php
// SPDX-License-Identifier: MIT
//
// Unit tests of src/functions.php: the URL-to-path rule, the parsing of
// sources, and the lockfile check.
//
//   php tests/unit/functions.php <Composer's vendor/autoload.php> \
//     src/functions.php tests/fixtures
//
// Prints one line per failed assertion and exits 1 if any failed.

declare(strict_types=1);

namespace ComposerPurifier;

use Composer\Config;
use Composer\Package\Package;

require $argv[1];
require $argv[2];
$fixtures = rtrim($argv[3], '/');

$failures = 0;

function same(mixed $expected, mixed $actual, string $what): void
{
    global $failures;
    if ($expected !== $actual) {
        $failures++;
        echo "FAIL {$what}: expected " . var_export($expected, true) . ', got ' . var_export($actual, true) . "\n";
    }
}

function throwsWith(string $needle, callable $call, string $what): void
{
    global $failures;
    try {
        $call();
        $failures++;
        echo "FAIL {$what}: no exception\n";
    } catch (PurifierException $e) {
        if (!str_contains($e->getMessage(), $needle)) {
            $failures++;
            echo "FAIL {$what}: the message \"{$e->getMessage()}\" does not contain \"{$needle}\"\n";
        }
    }
}

// The URL-to-path rule: the path that `composer install` looked up for
// monolog in a real cache (tests/fixtures/app).
same(
    'files/monolog/monolog/13f7456348238a63d970854498776d96f53cdee8.zip',
    cachePathFor('monolog/monolog', 'https://api.github.com/repos/Seldaek/monolog/zipball/d7059e4c691d05ea1222b5124bed0f961be46e15', 'zip'),
    'cachePathFor of a Packagist dist'
);
same(
    'files/vendor/a-b/' . hash('sha1', 'https://example.invalid/x') . '.tar',
    cachePathFor('vendor/a@b', 'https://example.invalid/x', 'tar'),
    'cachePathFor replaces characters outside the allowlist of Cache::copyTo'
);

// SSH git URLs become HTTPS URLs of the same repository.
same('https://github.com/php-fig/clock.git', httpsGitUrl('git@github.com:php-fig/clock.git'), 'httpsGitUrl of the scp-like syntax');
same('https://github.com/php-fig/clock.git', httpsGitUrl('ssh://git@github.com/php-fig/clock.git'), 'httpsGitUrl of an ssh URL');
same('https://gitlab.example.com/group/repo.git', httpsGitUrl('ssh://git@gitlab.example.com:2222/group/repo.git'), 'httpsGitUrl of an ssh URL with a port');
same('https://user@github.com/php-fig/clock.git', httpsGitUrl('https://user@github.com/php-fig/clock.git'), 'httpsGitUrl keeps an HTTPS URL');
same('/srv/git/repo.git', httpsGitUrl('/srv/git/repo.git'), 'httpsGitUrl keeps a local path');

// The checkout of each source kind.
same(
    ['url' => 'https://github.com/a/b.git', 'rev' => 'abc', 'submodules' => false, 'leaveDotGit' => false, 'commitObject' => null],
    checkoutOf('a/b', 'git', 'git@github.com:a/b.git', 'abc'),
    'checkoutOf git'
);
same(
    ['url' => 'https://example.invalid/hg', 'rev' => 'abc', 'subrepos' => true],
    checkoutOf('a/b', 'hg', 'https://example.invalid/hg', 'abc'),
    'checkoutOf hg'
);
same(
    ['url' => 'https://example.invalid/svn/trunk', 'rev' => '7', 'ignoreExternals' => false, 'ignoreKeywords' => false],
    checkoutOf('a/b', 'svn', 'https://example.invalid/svn/', '/trunk/@7'),
    'checkoutOf svn with a path'
);
same(
    ['url' => 'https://example.invalid/svn', 'rev' => '12', 'ignoreExternals' => false, 'ignoreKeywords' => false],
    checkoutOf('a/b', 'svn', 'https://example.invalid/svn', '@12'),
    'checkoutOf svn at the repository root'
);
same(
    ['url' => 'https://example.invalid/fossil', 'rev' => 'abc'],
    checkoutOf('a/b', 'fossil', 'https://example.invalid/fossil', 'abc'),
    'checkoutOf fossil'
);
throwsWith('names no revision number', fn () => checkoutOf('a/b', 'svn', 'https://example.invalid/svn', 'trunk'), 'checkoutOf svn without a revision');
throwsWith('no anonymous protocol', fn () => checkoutOf('a/b', 'perforce', '//depot/a', 'abc'), 'checkoutOf perforce');
throwsWith('neither a dist nor', fn () => checkoutOf('a/b', 'cvs', 'cvs://x', 'abc'), 'checkoutOf an unknown kind');

// The URLs of a dist: the reference goes into a legacy GitHub archive URL,
// and a mirror follows the dist URL.
$config = new Config(false);
$package = new Package('vendor/pkg', '1.0.0.0', '1.0.0');
$package->setDistType('zip');
$package->setDistUrl('https://github.com/vendor/pkg/zipball/master');
$package->setDistReference('0123456789abcdef0123456789abcdef01234567');
$package->setDistMirrors([['url' => 'https://mirror.example.invalid/%package%/%reference%.%type%', 'preferred' => false]]);
$urls = distUrls($config, $package);
same('https://api.github.com/repos/vendor/pkg/zipball/0123456789abcdef0123456789abcdef01234567', $urls[0], 'distUrls rewrites the reference of a GitHub archive URL');
same(2, count($urls), 'distUrls holds the dist URL and its mirror');
same(true, str_starts_with($urls[1] ?? '', 'https://mirror.example.invalid/vendor/pkg/'), 'distUrls fills the placeholders of a mirror');

// An old lockfile gives its hashes by download key.
$old = readOldLock("{$fixtures}/sources/composer-purifier.lock.json");
same('sha256-fRd1KrFaQj7Jc+yuwNlaEw2pXgDsJo5XlnGtDZxJPv8=', $old['hashes'][checkoutKey('git', 'https://github.com/php-fig/clock.git', 'b2eb66ddc49cb78166f16246b3c569acf82a5c16')] ?? null, 'readOldLock keys a checkout by kind, URL and revision');
same(['composerLock' => null, 'hashes' => []], readOldLock("{$fixtures}/malformed/version-1.json"), 'readOldLock ignores another format version');

// The lockfile check.
$composerLock = (string) file_get_contents("{$fixtures}/app/composer.lock");
$lock = (string) file_get_contents("{$fixtures}/app/composer-purifier.lock.json");
checkLock($lock, $composerLock);
throwsWith('composer.lock changed', fn () => checkLock($lock, $composerLock . "\n"), 'checkLock of a stale lockfile');
throwsWith('was edited after `composer-purifier lock` wrote it', fn () => checkLock((string) file_get_contents("{$fixtures}/edited/tampered-hash.json"), $composerLock), 'checkLock of a lockfile with an edited hash');

// The content hash: canonical JSON as builtins.toJSON writes it.
same('{"a":[],"b":{},"c":null,"d":"x/y","e":[1,true]}', canonicalJson(['e' => [1, true], 'd' => 'x/y', 'c' => null, 'b' => new \stdClass(), 'a' => []]), 'canonicalJson sorts keys and keeps empty objects and lists');
same(json_decode($lock, true)['contentHash'], contentHash(json_decode($lock, false)), 'contentHash of the app lockfile');
throwsWith('is not valid JSON', fn () => checkLock('{"version": 2,', $composerLock), 'checkLock of a lockfile that is not JSON');
throwsWith('lock format version 1', fn () => checkLock((string) file_get_contents("{$fixtures}/malformed/version-1.json"), $composerLock), 'checkLock of another format version');
throwsWith('without a path or a hash', fn () => checkLock((string) file_get_contents("{$fixtures}/malformed/entry-without-hash.json"), $composerLock), 'checkLock of an entry without a hash');
throwsWith('no valid `packages` field', fn () => checkLock((string) file_get_contents("{$fixtures}/malformed/no-packages.json"), $composerLock), 'checkLock of a lockfile without packages');
throwsWith('names no download for psr/log', fn () => checkLock((string) file_get_contents("{$fixtures}/edited/missing-package.json"), $composerLock), 'checkLock of a lockfile without a package');
throwsWith('which composer.lock does not have', fn () => checkLock((string) file_get_contents("{$fixtures}/edited/extra-package.json"), $composerLock), 'checkLock of a lockfile with an extra package');
throwsWith('but has no entry at that path', fn () => checkLock((string) file_get_contents("{$fixtures}/edited/missing-entry.json"), $composerLock), 'checkLock of a lockfile without an entry');

if ($failures > 0) {
    echo "{$failures} assertions failed\n";
    exit(1);
}
echo "all assertions passed\n";
