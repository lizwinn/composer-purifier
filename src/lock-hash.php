<?php
// SPDX-License-Identifier: MIT
//
// Prints the contentHash of a lockfile, which `composer-purifier prefetch`
// records and the offline `composer install` compares, or nothing for an
// unreadable lockfile:
//
//   php lock-hash.php <lockfile>

declare(strict_types=1);

$lock = json_decode((string) @file_get_contents($argv[1] ?? ''), true);
echo is_array($lock) ? (string) ($lock['contentHash'] ?? '') : '';
