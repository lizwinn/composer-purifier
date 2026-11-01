<?php
// SPDX-License-Identifier: MIT
//
// The lockfile check of `composer-purifier install`, for the Composer
// project in the current directory:
//
//   php check.php
//
// Exits 0 when composer-purifier.lock.json is one this version reads, was
// made from the current composer.lock, and names every package of it.
// Otherwise it prints what is wrong and the command that fixes it, and
// exits 1 (checkLock in functions.php).

declare(strict_types=1);

namespace ComposerPurifier;

require __DIR__ . '/functions.php';

try {
    if (!is_file(LOCK_FILE)) {
        throw new PurifierException('there is no ' . LOCK_FILE . ' in ' . getcwd() . '. Run `composer-purifier lock` first.');
    }
    if (!is_file('composer.lock')) {
        throw new PurifierException('there is no composer.lock in ' . getcwd() . '. Run `composer update` first.');
    }
    checkLock((string) file_get_contents(LOCK_FILE), (string) file_get_contents('composer.lock'));
} catch (PurifierException $e) {
    fwrite(STDERR, "composer-purifier: {$e->getMessage()}\n");
    exit(1);
}
