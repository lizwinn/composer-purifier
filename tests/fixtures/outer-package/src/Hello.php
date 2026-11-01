<?php

declare(strict_types=1);

namespace Fixture\Outer;

final class Hello
{
    public static function text(): string
    {
        return 'hello from the path package outside the project';
    }
}
