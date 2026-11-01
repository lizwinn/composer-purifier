<?php
// SPDX-License-Identifier: MIT
//
// The lockfile check of `composer-purifier prefetch` and of the offline
// `composer install`, for the Composer project in the current directory:
//
//   php check.php [<lockfile> [<composer.lock>]]
//
// The lockfile is composer-purifier.lock.json in the current directory
// unless a path is given, and composer.lock is the one in the current
// directory unless a path is given. Exits 0 when the lockfile is one this
// version reads, was made from that composer.lock, and names every package
// of it. Otherwise it prints what is wrong and the command that fixes it,
// and exits 1 (checkLock in functions.php).

declare(strict_types=1);

namespace ComposerPurifier;

require __DIR__ . '/functions.php';

$lockFile = $argv[1] ?? LOCK_FILE;
$composerLock = ($argv[2] ?? '') !== '' ? $argv[2] : 'composer.lock';
try {
    if (!is_file($lockFile)) {
        throw new PurifierException("there is no {$lockFile} in " . getcwd() . '. Run `composer-purifier lock` first.');
    }
    if (!is_file($composerLock)) {
        throw new PurifierException("there is no {$composerLock} in " . getcwd() . '. Run `composer update` first.');
    }
    checkLock((string) file_get_contents($lockFile), (string) file_get_contents($composerLock));
} catch (PurifierException $e) {
    fwrite(STDERR, "composer-purifier: {$e->getMessage()}\n");
    exit(1);
}
