<?php
// SPDX-License-Identifier: MIT
//
// Sets the contentHash of a lockfile to the hash of its content, for the
// faulty lockfiles of tests/derive-negative-fixtures.sh whose fault is not
// the edit itself:
//
//   php tests/rehash.php <lockfile>

declare(strict_types=1);

namespace ComposerPurifier;

require __DIR__ . '/../src/functions.php';

$file = $argv[1];
$lock = json_decode((string) file_get_contents($file), false, 512, JSON_THROW_ON_ERROR);
$lock->contentHash = contentHash($lock);
file_put_contents($file, json_encode($lock, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
