<?php
declare(strict_types=1);

namespace App\Services\Import;

/**
 * Where the MariaDB version's data is read from: the live server, or a dump
 * of it. MariaDbImporter copies from either in the same way.
 *
 * Every value a source hands over is already what the MariaDB application
 * would have read: text in UTF-8, and every date and time in APP_TIMEZONE —
 * including TIMESTAMP columns, which MariaDB stores in UTC and a dump may
 * well have written in UTC.
 */
interface MariaDbSource
{
    /** One line saying what is being read, for the screen. */
    public function describe(): string;

    /**
     * The base tables, each with its columns in MariaDB order.
     *
     * @return array<string,list<array{name:string,type:string,generated:bool}>>
     */
    public function tables(): array;

    /**
     * The rows of schema_migrations: which migrations the data was written
     * under.
     *
     * @return list<array{migration:string,batch:int,applied_at:?string}>
     */
    public function migrations(): array;

    /** The table's next AUTO_INCREMENT value, when the source knows it. */
    public function autoIncrement(string $table): ?int;

    /**
     * Hand every row of every table to $onRow, as column => value. Generated
     * columns are left out; binary values arrive as BinaryValue.
     *
     * @param callable(string, array<string,mixed>): void $onRow
     */
    public function eachRow(callable $onRow): void;
}
