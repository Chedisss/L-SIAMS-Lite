<?php
declare(strict_types=1);

namespace App\Services\Import;

/** Bytes from a VARBINARY/BLOB column, to be stored as a BLOB rather than text. */
final class BinaryValue
{
    public function __construct(public readonly string $bytes)
    {
    }
}
