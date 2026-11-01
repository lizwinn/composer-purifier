<?php

declare(strict_types=1);

namespace Fixture\Inner;

final class Hello
{
    public static function text(): string
    {
        return 'hello from the path package inside the project';
    }
}
