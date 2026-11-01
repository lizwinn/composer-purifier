<?php

declare(strict_types=1);

namespace Fixture;

final class Greeting
{
    public static function text(): string
    {
        // bzcompress comes from ext-bz2, which composer.json requires and the
        // default nixpkgs PHP does not load.
        $packed = bzcompress('hello from composer-purifier');

        return bzdecompress($packed);
    }
}
