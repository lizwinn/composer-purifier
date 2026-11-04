<?php

declare(strict_types=1);

// The test of the fixture, which `composer test` runs.

require __DIR__ . '/../vendor/autoload.php';

if (Fixture\Greeting::text() !== 'hello from composer-purifier') {
    fwrite(STDERR, "Greeting::text returned the wrong text\n");
    exit(1);
}
echo "the greeting test passed\n";
