<?php
// SPDX-License-Identifier: MIT
//
// The lockfile check of `composer-purifier prefetch` and of the offline
// `composer install`, for the Composer project in the current directory:
//
//   php check.php [<lockfile>]
//
// The lockfile is composer-purifier.lock.json in the current directory
// unless a path is given. Exits 0 when the lockfile is one this version
// reads, was made from the current composer.lock, and names every package
// of it. Otherwise it prints what is wrong and the command that fixes it,
// and exits 1 (checkLock in functions.php).

declare(strict_types=1);

namespace ComposerPurifier;

require __DIR__ . '/functions.php';

$lockFile = $argv[1] ?? LOCK_FILE;
try {
    if (!is_file($lockFile)) {
        throw new PurifierException("there is no {$lockFile} in " . getcwd() . '. Run `composer-purifier lock` first.');
    }
    if (!is_file('composer.lock')) {
        throw new PurifierException('there is no composer.lock in ' . getcwd() . '. Run `composer update` first.');
    }
    checkLock((string) file_get_contents($lockFile), (string) file_get_contents('composer.lock'));
} catch (PurifierException $e) {
    fwrite(STDERR, "composer-purifier: {$e->getMessage()}\n");
    exit(1);
}
