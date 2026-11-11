<?php
declare(strict_types=1);

namespace App\Services\Export;

/**
 * Dependency-free PDF writer for tabular reports.
 *
 * Emits a valid PDF 1.4 document using the base-14 Helvetica fonts, which every
 * reader has built in — no font embedding, no external library, no
 * `composer install` on an air-gapped server. It handles the layout this system
 * actually needs: a titled, branded header block, a repeating table header
 * across pages, zebra striping, and page numbering.
 */
final class PdfWriter
{
    private const PAGE_WIDTH  = 841.89;  // A4 landscape, points
    private const PAGE_HEIGHT = 595.28;
    private const MARGIN      = 32.0;
    private const ROW_HEIGHT  = 16.0;
    private const HEADER_SIZE = 8.5;
    private const BODY_SIZE   = 8.0;

    /** @var list<string> */
    private array $pages = [];
    private string $currentPage = '';
    private float $cursorY = 0.0;
    private int $pageNumber = 0;

    /** @var list<string> */
    private array $headers = [];
    /** @var list<float> */
    private array $columnWidths = [];

    private string $title;
    private string $subtitle;
    /** @var array<string,string> */
    private array $meta;
    private string $schoolName;

    /** @param array<string,string> $meta */
    private function __construct(string $title, string $subtitle, array $meta, string $schoolName)
    {
        $this->title      = $title;
        $this->subtitle   = $subtitle;
        $this->meta       = $meta;
        $this->schoolName = $schoolName;
    }

    /**
     * @param list<string>                  $headers
     * @param list<array<string|int,mixed>> $rows
     * @param array<string,string>          $meta       filter summary shown under the title
     * @param array<string,string|int|float> $statistics summary chips above the table
     */
    public static function table(
        string $title,
        array $headers,
        array $rows,
        string $subtitle = '',
        array $meta = [],
        array $statistics = [],
        string $schoolName = 'L-SIAMS'
    ): string {
        $writer = new self($title, $subtitle, $meta, $schoolName);
        $writer->setHeaders($headers, $rows);
        $writer->startPage();

        if ($statistics !== []) {
            $writer->drawStatistics($statistics);
        }

        $writer->drawTableHeader();

        $striped = false;

        foreach ($rows as $row) {
            if ($writer->cursorY < self::MARGIN + 40) {
                $writer->finishPage();
                $writer->startPage();
                $writer->drawTableHeader();
            }

            $writer->drawRow(array_values($row), $striped);
            $striped = !$striped;
        }

        if ($rows === []) {
            $writer->drawEmptyState();
        }

        $writer->finishPage();

        return $writer->render();
    }

    /**
     * Render a DepEd School Form 2 (SF2) as a bordered monthly register.
     *
     * One landscape grid: the header block, a two-row column header (date over
     * day letter), the male and female registers each with a per-day present
     * count, a combined total, a short legend, and the certification lines. A
     * long roster flows onto further pages, repeating the column header. The
     * data shape is the 'sf2' payload from ReportService::schoolFormTwo.
     *
     * @param array<string,mixed> $sf2
     */
    public static function schoolFormTwo(array $sf2, string $schoolName = 'L-SIAMS'): string
    {
        $writer = new self('School Form 2 (SF2)', '', [], $schoolName);
        return $writer->renderSf2($sf2);
    }

    /** @param array<string,mixed> $sf2 */
    private function renderSf2(array $sf2): string
    {
        /** @var list<array{date:string,dom:int,dow:string}> $days */
        $days = $sf2['days'] ?? [];
        $dayN = max(count($days), 1);

        $left   = self::MARGIN;
        $right  = self::PAGE_WIDTH - self::MARGIN;
        $usable = $right - $left;

        $wNum = 20.0;
        $wName = 150.0;
        $wAbs = 30.0;
        $wTar = 30.0;
        $wRem = 80.0;
        $dayW = max(12.0, ($usable - $wNum - $wName - $wAbs - $wTar - $wRem) / $dayN);

        // Left edge x of each column: #, name, day0..dayN-1, absent, tardy, remarks.
        $edges = [$left, $left + $wNum, $left + $wNum + $wName];
        for ($i = 1; $i <= $dayN; $i++) {
            $edges[] = $edges[count($edges) - 1] + $dayW;
        }
        $edges[] = $edges[count($edges) - 1] + $wAbs;
        $edges[] = $edges[count($edges) - 1] + $wTar;
        $edges[] = $edges[count($edges) - 1] + $wRem;
        $gridRight = $edges[count($edges) - 1];
        $absIdx = 2 + $dayN;      // index into $edges of the ABSENT column's left edge
        $rh = 13.5;

        $this->startPage(false);
        $this->sf2Header($sf2, $gridRight);

        // Column header, repeated on each page.
        $drawColHeader = function () use (&$days, $dayN, $edges, $absIdx, $rh): void {
            $top = $this->cursorY;
            $h1  = $top;
            $h2  = $top - $rh;
            // vertical separators for both header rows
            for ($k = 0; $k < count($edges); $k++) {
                $this->line($edges[$k], $top, $edges[$k], $top - 2 * $rh, 0.3, 0.3, 0.3);
            }
            $this->line($edges[0], $top, $edges[count($edges) - 1], $top, 0.3, 0.3, 0.3);
            $this->line($edges[0], $h2, $edges[count($edges) - 1], $h2, 0.3, 0.3, 0.3);
            $this->line($edges[0], $top - 2 * $rh, $edges[count($edges) - 1], $top - 2 * $rh, 0.3, 0.3, 0.3);
            // # and NAME span both rows
            $this->sf2CellText($edges[0], $edges[1], $top - $rh - 3, '#', 'center', 7.5, true);
            $this->sf2CellText($edges[1] + 2, $edges[2], $top - $rh - 3, "LEARNER'S NAME (Last, First, Middle)", 'left', 7.5, true);
            // day numbers (row 1) + letters (row 2)
            foreach ($days as $i => $d) {
                $this->sf2CellText($edges[2 + $i], $edges[3 + $i], $h1 - 10, (string) $d['dom'], 'center', 7, true);
                $this->sf2CellText($edges[2 + $i], $edges[3 + $i], $h2 - 10, (string) $d['dow'], 'center', 6.5, false);
            }
            // ABSENT / TARDY / REMARKS
            $this->sf2CellText($edges[$absIdx], $edges[$absIdx + 1], $h2 - 10, 'ABS', 'center', 6.5, true);
            $this->sf2CellText($edges[$absIdx + 1], $edges[$absIdx + 2], $h2 - 10, 'TDY', 'center', 6.5, true);
            $this->sf2CellText($edges[$absIdx + 2], $edges[$absIdx + 3], $top - $rh - 3, 'REMARKS', 'center', 6.5, true);
            $this->cursorY = $top - 2 * $rh;
        };
        $drawColHeader();

        // A single grid data row.
        $drawGridRow = function (string $no, string $name, array $marks, string $absent, string $tardy, bool $bold = false) use ($edges, $dayN, $absIdx, $rh): void {
            $top = $this->cursorY;
            $bot = $top - $rh;
            foreach ($marks as $i => $m) {
                if ($m === 'T') {
                    // tardy: shade the cell
                    $this->rect($edges[2 + $i], $bot, $edges[3 + $i] - $edges[2 + $i], $rh, 0.75, 0.75, 0.75);
                }
            }
            for ($k = 0; $k < count($edges); $k++) {
                $this->line($edges[$k], $top, $edges[$k], $bot, 0.3, 0.3, 0.3);
            }
            $this->line($edges[0], $bot, $edges[count($edges) - 1], $bot, 0.3, 0.3, 0.3);
            $this->sf2CellText($edges[0], $edges[1], $bot + 3.5, $no, 'center', 7, $bold);
            $this->sf2CellText($edges[1] + 2, $edges[2], $bot + 3.5, $name, 'left', 7, $bold);
            foreach ($marks as $i => $m) {
                if ($m === 'x') {
                    $this->sf2CellText($edges[2 + $i], $edges[3 + $i], $bot + 3.5, 'x', 'center', 7, false);
                }
            }
            $this->sf2CellText($edges[$absIdx], $edges[$absIdx + 1], $bot + 3.5, $absent, 'center', 7, $bold);
            $this->sf2CellText($edges[$absIdx + 1], $edges[$absIdx + 2], $bot + 3.5, $tardy, 'center', 7, $bold);
            $this->cursorY = $bot;
        };

        $pageBreak = function () use ($drawColHeader, $rh): void {
            if ($this->cursorY < self::MARGIN + 3 * $rh) {
                $this->finishPage();
                $this->startPage(false);
                $this->cursorY = self::PAGE_HEIGHT - self::MARGIN - 6;
                $drawColHeader();
            }
        };

        $emit = function (array $block, array $totals, string $totalLabel) use (&$pageBreak, $drawGridRow, $dayN): void {
            foreach ($block as $i => $e) {
                $pageBreak();
                $drawGridRow(
                    (string) ($i + 1),
                    (string) $e['name'],
                    $e['marks'] ?? [],
                    (string) (((int) ($e['absent'] ?? 0)) ?: ''),
                    (string) (((int) ($e['tardy'] ?? 0)) ?: '')
                );
            }
            $pageBreak();
            $marks = array_fill(0, $dayN, '');
            $totalsTxt = [];
            for ($i = 0; $i < $dayN; $i++) {
                $totalsTxt[$i] = ($totals[$i] ?? 0) !== 0 ? (string) $totals[$i] : '';
            }
            $this->sf2TotalRow($totalLabel, $totalsTxt, $dayN);
        };

        $emit($sf2['males'] ?? [], $sf2['male_totals'] ?? [], 'MALE | TOTAL Per Day');
        $emit($sf2['females'] ?? [], $sf2['female_totals'] ?? [], 'FEMALE | TOTAL Per Day');
        $pageBreak();
        $combined = [];
        for ($i = 0; $i < $dayN; $i++) {
            $combined[$i] = ($sf2['combined_totals'][$i] ?? 0) !== 0 ? (string) $sf2['combined_totals'][$i] : '';
        }
        $this->sf2TotalRow('Combined TOTAL Per Day', $combined, $dayN);

        // Legend + certification.
        $this->cursorY -= 18;
        $this->text($left, $this->cursorY, 'Codes:  blank = Present      x = Absent      shaded cell = Tardy', 7.5, false, 0.3, 0.3, 0.3);
        $this->cursorY -= 28;
        $this->text($left + 20, $this->cursorY, 'I certify that this is a true and correct report.', 8, false, 0.12, 0.16, 0.23);
        $this->cursorY -= 26;
        $this->text($left + 40, $this->cursorY, strtoupper((string) ($sf2['adviser'] ?? '')), 9, true, 0.12, 0.16, 0.23);
        $this->text($left + 360, $this->cursorY, strtoupper((string) ($sf2['head'] ?? '')), 9, true, 0.12, 0.16, 0.23);
        $this->cursorY -= 11;
        $this->text($left + 40, $this->cursorY, 'Signature of Teacher / Adviser over Printed Name', 7, false, 0.42, 0.45, 0.50);
        $this->text($left + 360, $this->cursorY, 'Signature of School Head over Printed Name', 7, false, 0.42, 0.45, 0.50);

        $this->finishPage();
        return $this->render();
    }

    /** @param array<string,mixed> $sf2 */
    private function sf2Header(array $sf2, float $gridRight): void
    {
        $left = self::MARGIN;
        $y    = self::PAGE_HEIGHT - self::MARGIN - 8;
        $title = 'School Form 2 (SF2) — Daily Attendance Report of Learners';
        $this->text(($left + $gridRight) / 2 - $this->textWidth($title, 12) / 2, $y, $title, 12, true, 0.12, 0.16, 0.23);
        $y -= 20;

        $field = function (float $x, string $label, string $value, float $y): void {
            $this->text($x, $y, $label . ':', 8, true, 0.12, 0.16, 0.23);
            $this->text($x + $this->textWidth($label . ': ', 8) + 2, $y, $value, 8, false, 0.2, 0.2, 0.2);
        };
        $col2 = $left + 260;
        $col3 = $left + 500;
        $field($left, 'School ID', (string) ($sf2['school_id'] ?? ''), $y);
        $field($col2, 'School Year', (string) ($sf2['school_year'] ?? ''), $y);
        $field($col3, 'Report for the Month of', (string) ($sf2['month'] ?? ''), $y);
        $y -= 15;
        $field($left, 'Name of School', (string) ($sf2['school_name'] ?? ''), $y);
        $field($col3, 'Grade & Section', trim(sprintf('Grade %s - %s', (string) ($sf2['grade'] ?? ''), (string) ($sf2['section'] ?? '')), ' -'), $y);

        $this->cursorY = $y - 16;
    }

    /** @param array<int,string> $totals */
    private function sf2TotalRow(string $label, array $totals, int $dayN): void
    {
        $this->drawSf2TotalRowInner($label, $totals, $dayN);
    }

    /**
     * Draw text clipped to a cell, horizontally aligned. $yBaseline is the text
     * baseline in PDF points.
     */
    private function sf2CellText(float $x1, float $x2, float $yBaseline, string $text, string $align, float $size, bool $bold): void
    {
        if ($text === '') {
            return;
        }
        $maxW = $x2 - $x1 - 4;
        while ($text !== '' && $this->textWidth($text, $size) > $maxW) {
            $text = mb_substr($text, 0, -1);
        }
        $w = $this->textWidth($text, $size);
        $x = match ($align) {
            'center' => $x1 + (($x2 - $x1) - $w) / 2,
            'right'  => $x2 - 2 - $w,
            default  => $x1 + 2,
        };
        $this->text($x, $yBaseline, $text, $size, $bold, 0.12, 0.16, 0.23);
    }

    /** @param array<int,string> $totals */
    private function drawSf2TotalRowInner(string $label, array $totals, int $dayN): void
    {
        // Rebuild edges the same way renderSf2 did — kept local so the totals
        // row lines up with the grid above it.
        $left   = self::MARGIN;
        $usable = (self::PAGE_WIDTH - self::MARGIN) - $left;
        $wNum = 20.0; $wName = 150.0; $wAbs = 30.0; $wTar = 30.0; $wRem = 80.0;
        $dayW = max(12.0, ($usable - $wNum - $wName - $wAbs - $wTar - $wRem) / max($dayN, 1));
        $edges = [$left, $left + $wNum, $left + $wNum + $wName];
        for ($i = 1; $i <= $dayN; $i++) {
            $edges[] = $edges[count($edges) - 1] + $dayW;
        }
        $edges[] = $edges[count($edges) - 1] + $wAbs;
        $edges[] = $edges[count($edges) - 1] + $wTar;
        $edges[] = $edges[count($edges) - 1] + $wRem;

        $rh  = 13.5;
        $top = $this->cursorY;
        $bot = $top - $rh;
        for ($k = 0; $k < count($edges); $k++) {
            $this->line($edges[$k], $top, $edges[$k], $bot, 0.3, 0.3, 0.3);
        }
        $this->line($edges[0], $bot, $edges[count($edges) - 1], $bot, 0.3, 0.3, 0.3);
        $this->sf2CellText($edges[0] + 2, $edges[2], $bot + 3.5, $label, 'left', 7, true);
        foreach ($totals as $i => $t) {
            $this->sf2CellText($edges[2 + $i], $edges[3 + $i], $bot + 3.5, (string) $t, 'center', 7, true);
        }
        $this->cursorY = $bot;
    }

    /**
     * A booklet: one titled sheet per entity, each starting on its own page.
     *
     * The single-table `table()` renderer answers "one report, many rows"; this
     * answers "many little reports, one page each" — a per-student attendance
     * card for report-card season, where every student's page carries their own
     * header, their own summary chips and their own day-by-day table, and a
     * student whose record runs long simply continues onto a second page that
     * repeats their name. Every sheet reuses the same drawing primitives as the
     * table renderer, so the two never drift apart in look.
     *
     * @param list<array{
     *     title:string,
     *     subtitle?:string,
     *     meta?:array<string,string>,
     *     statistics?:array<string,string|int|float>,
     *     headers:list<string>,
     *     rows:list<array<int|string,mixed>>
     * }> $sheets
     */
    public static function booklet(array $sheets, string $schoolName = 'L-SIAMS'): string
    {
        $writer = new self('', '', [], $schoolName);

        if ($sheets === []) {
            $writer->setHeaders(['']);
            $writer->startPage();
            $writer->drawEmptyState();
            $writer->finishPage();

            return $writer->render();
        }

        foreach ($sheets as $sheet) {
            $writer->title    = $sheet['title'];
            $writer->subtitle = $sheet['subtitle'] ?? '';
            $writer->meta     = $sheet['meta'] ?? [];
            $writer->setHeaders($sheet['headers']);

            // Each sheet begins on a fresh page: startPage() redraws the brand
            // bar and this student's header block.
            $writer->startPage();

            if (!empty($sheet['statistics'])) {
                $writer->drawStatistics($sheet['statistics']);
            }

            $writer->drawTableHeader();

            $striped = false;

            foreach ($sheet['rows'] as $row) {
                if ($writer->cursorY < self::MARGIN + 40) {
                    $writer->finishPage();
                    $writer->startPage();
                    $writer->drawTableHeader();
                }

                $writer->drawRow(array_values($row), $striped);
                $striped = !$striped;
            }

            if ($sheet['rows'] === []) {
                $writer->drawEmptyState();
            }

            $writer->finishPage();
        }

        return $writer->render();
    }

    /**
     * @param list<string>                  $headers
     * @param list<array<string|int,mixed>> $rows
     */
    private function setHeaders(array $headers, array $rows = []): void
    {
        $this->headers = $headers;
        $available     = self::PAGE_WIDTH - (self::MARGIN * 2);
        $count         = max(1, count($headers));

        // Weight each column by its header length so "Student Name" gets more
        // room than "Status", rather than dividing the page evenly.
        $weights = array_map(static fn (string $h): float => max(6.0, min(22.0, (float) mb_strlen($h))), $headers);

        // With rows to go on, weight by what the column actually holds: its
        // longest value, capped so one very long cell cannot starve the rest.
        // The header still counts, but only up to 12 characters, so a long
        // header over short values ("Attendance Percentage" over "95%") does
        // not take the room a teacher's name needs.
        if ($rows !== []) {
            $sample = array_slice($rows, 0, 500);

            foreach ($weights as $index => $_) {
                $lengths = array_map(
                    static fn (array $row): int => mb_strlen(self::stringify(array_values($row)[$index] ?? '')),
                    $sample
                );
                $longest = (float) max($lengths);

                $weights[$index] = max(5.0, min(26.0, max($longest, min(12.0, (float) mb_strlen($headers[$index])))));
            }
        }

        $sum = array_sum($weights) ?: (float) $count;

        $this->columnWidths = array_map(
            static fn (float $w): float => $available * ($w / $sum),
            $weights
        );
    }

    private function startPage(bool $branded = true): void
    {
        $this->pageNumber++;
        $this->currentPage = '';
        $this->cursorY     = self::PAGE_HEIGHT - self::MARGIN;

        if ($branded) {
            $this->drawDocumentHeader();
        }
    }

    private function finishPage(): void
    {
        $this->drawFooter();
        $this->pages[] = $this->currentPage;
    }

    private function drawDocumentHeader(): void
    {
        // Brand bar in the L-SIAMS primary blue (#2563EB).
        $this->rect(0, self::PAGE_HEIGHT - 46, self::PAGE_WIDTH, 46, 0.145, 0.388, 0.922);

        $this->text(self::MARGIN, self::PAGE_HEIGHT - 24, $this->schoolName, 13, true, 1, 1, 1);
        $this->text(self::MARGIN, self::PAGE_HEIGHT - 38, 'L-SIAMS · Attendance Monitoring System', 7.5, false, 1, 1, 1);

        $generated = 'Generated ' . date('M j, Y g:i A');
        $this->text(
            self::PAGE_WIDTH - self::MARGIN - $this->textWidth($generated, 7.5),
            self::PAGE_HEIGHT - 38,
            $generated,
            7.5,
            false,
            1,
            1,
            1
        );

        $this->cursorY = self::PAGE_HEIGHT - 64;

        $this->text(self::MARGIN, $this->cursorY, $this->title, 14, true, 0.12, 0.16, 0.23);
        $this->cursorY -= 15;

        if ($this->subtitle !== '') {
            $this->text(self::MARGIN, $this->cursorY, $this->subtitle, 9, false, 0.42, 0.45, 0.50);
            $this->cursorY -= 13;
        }

        if ($this->meta !== []) {
            $parts = [];

            foreach ($this->meta as $label => $value) {
                if ($value !== '') {
                    $parts[] = $label . ': ' . $value;
                }
            }

            if ($parts !== []) {
                foreach (self::wrap(implode('   ·   ', $parts), 150) as $line) {
                    $this->text(self::MARGIN, $this->cursorY, $line, 8, false, 0.42, 0.45, 0.50);
                    $this->cursorY -= 11;
                }
            }
        }

        $this->cursorY -= 6;
    }

    /** @param array<string,string|int|float> $statistics */
    private function drawStatistics(array $statistics): void
    {
        $x        = self::MARGIN;
        $boxWidth = 108.0;
        $boxHeight = 34.0;
        $top      = $this->cursorY;

        foreach ($statistics as $label => $value) {
            if ($x + $boxWidth > self::PAGE_WIDTH - self::MARGIN) {
                break;
            }

            $this->rect($x, $top - $boxHeight, $boxWidth, $boxHeight, 0.949, 0.965, 0.984);
            $this->text($x + 8, $top - 13, mb_strtoupper((string) $label), 6.5, false, 0.42, 0.45, 0.50);
            $this->text($x + 8, $top - 27, (string) $value, 12, true, 0.12, 0.16, 0.23);

            $x += $boxWidth + 8;
        }

        $this->cursorY = $top - $boxHeight - 14;
    }

    private function drawTableHeader(): void
    {
        $this->rect(
            self::MARGIN,
            $this->cursorY - self::ROW_HEIGHT + 4,
            self::PAGE_WIDTH - (self::MARGIN * 2),
            self::ROW_HEIGHT,
            0.117,
            0.161,
            0.231
        );

        $x = self::MARGIN;

        foreach ($this->headers as $index => $header) {
            $width = $this->columnWidths[$index] ?? 60.0;
            $this->text(
                $x + 4,
                $this->cursorY - 8,
                $this->truncate($header, $width - 8, self::HEADER_SIZE),
                self::HEADER_SIZE,
                true,
                1,
                1,
                1
            );
            $x += $width;
        }

        $this->cursorY -= self::ROW_HEIGHT + 2;
    }

    /** @param list<mixed> $cells */
    private function drawRow(array $cells, bool $striped): void
    {
        if ($striped) {
            $this->rect(
                self::MARGIN,
                $this->cursorY - self::ROW_HEIGHT + 5,
                self::PAGE_WIDTH - (self::MARGIN * 2),
                self::ROW_HEIGHT,
                0.973,
                0.980,
                0.988
            );
        }

        $x = self::MARGIN;

        foreach ($this->headers as $index => $_) {
            $width = $this->columnWidths[$index] ?? 60.0;
            $value = $cells[$index] ?? '';

            $this->text(
                $x + 4,
                $this->cursorY - 7,
                $this->truncate(self::stringify($value), $width - 8, self::BODY_SIZE),
                self::BODY_SIZE,
                false,
                0.12,
                0.16,
                0.23
            );

            $x += $width;
        }

        $this->cursorY -= self::ROW_HEIGHT;
    }

    private function drawEmptyState(): void
    {
        $message = 'No records match the selected filters.';
        $this->text(
            (self::PAGE_WIDTH - $this->textWidth($message, 10)) / 2,
            $this->cursorY - 30,
            $message,
            10,
            false,
            0.55,
            0.58,
            0.62
        );
        $this->cursorY -= 50;
    }

    private function drawFooter(): void
    {
        $this->line(self::MARGIN, self::MARGIN + 16, self::PAGE_WIDTH - self::MARGIN, self::MARGIN + 16, 0.85, 0.87, 0.90);

        $left = 'L-SIAMS — confidential attendance record';
        $this->text(self::MARGIN, self::MARGIN + 5, $left, 7, false, 0.55, 0.58, 0.62);

        $right = 'Page ' . $this->pageNumber;
        $this->text(
            self::PAGE_WIDTH - self::MARGIN - $this->textWidth($right, 7),
            self::MARGIN + 5,
            $right,
            7,
            false,
            0.55,
            0.58,
            0.62
        );
    }

    // ------------------------------------------------------- primitives --

    private function text(float $x, float $y, string $value, float $size, bool $bold, float $r, float $g, float $b): void
    {
        $this->currentPage .= sprintf(
            "BT /%s %.2f Tf %.3f %.3f %.3f rg %.2f %.2f Td (%s) Tj ET\n",
            $bold ? 'F2' : 'F1',
            $size,
            $r,
            $g,
            $b,
            $x,
            $y,
            self::escape($value)
        );
    }

    private function rect(float $x, float $y, float $width, float $height, float $r, float $g, float $b): void
    {
        $this->currentPage .= sprintf(
            "%.3f %.3f %.3f rg %.2f %.2f %.2f %.2f re f\n",
            $r,
            $g,
            $b,
            $x,
            $y,
            $width,
            $height
        );
    }

    private function line(float $x1, float $y1, float $x2, float $y2, float $r, float $g, float $b): void
    {
        $this->currentPage .= sprintf(
            "%.3f %.3f %.3f RG 0.5 w %.2f %.2f m %.2f %.2f l S\n",
            $r,
            $g,
            $b,
            $x1,
            $y1,
            $x2,
            $y2
        );
    }

    /** Helvetica averages ~0.5 em per character — close enough for column fitting. */
    private function textWidth(string $value, float $size): float
    {
        return mb_strlen($value) * $size * 0.5;
    }

    private function truncate(string $value, float $maxWidth, float $size): string
    {
        $value    = trim(preg_replace('/\s+/u', ' ', $value) ?? $value);
        $maxChars = (int) floor($maxWidth / ($size * 0.5));

        if ($maxChars < 1) {
            return '';
        }

        return mb_strlen($value) <= $maxChars ? $value : mb_substr($value, 0, max(1, $maxChars - 1)) . '…';
    }

    /** @return list<string> */
    private static function wrap(string $value, int $width): array
    {
        return explode("\n", wordwrap($value, $width, "\n", true));
    }

    private static function stringify(mixed $value): string
    {
        if ($value === null) {
            return '—';
        }
        if (is_bool($value)) {
            return $value ? 'Yes' : 'No';
        }
        if (is_array($value)) {
            return implode(', ', array_map('strval', $value));
        }

        return (string) $value;
    }

    /**
     * PDF string escaping. Non-ASCII is transliterated because the base-14
     * fonts use WinAnsi encoding; embedding a Unicode font would triple the
     * file size for no practical gain on these reports.
     */
    private static function escape(string $value): string
    {
        $value = str_replace(
            ['—', '–', '·', '“', '”', '‘', '’', '…', '•', '≥', '≤'],
            ['-', '-', '-', '"', '"', "'", "'", '...', '*', '>=', '<='],
            $value
        );

        // iconv transliterates best — "Sección" becomes "Seccion" rather than
        // "Secci?n" — but ext-iconv is not guaranteed to be compiled in, and
        // an undefined function here is a fatal error and a blank 500 on the
        // one export format that is supposed to work everywhere. mbstring is a
        // required extension, so it is the fallback; stripping to ASCII is the
        // last resort.
        $converted = function_exists('iconv')
            ? @iconv('UTF-8', 'Windows-1252//TRANSLIT', $value)
            : @mb_convert_encoding($value, 'Windows-1252', 'UTF-8');

        $value = is_string($converted) ? $converted : preg_replace('/[^\x20-\x7E]/', '?', $value) ?? '';

        return str_replace(['\\', '(', ')', "\r", "\n"], ['\\\\', '\\(', '\\)', '', ' '], $value);
    }

    private function render(): string
    {
        $objects   = [];
        $pageCount = count($this->pages);

        // 1: Catalog, 2: Pages, 3: F1, 4: F2, then page + content pairs.
        $objects[1] = "<< /Type /Catalog /Pages 2 0 R >>";

        $kids = [];
        for ($i = 0; $i < $pageCount; $i++) {
            $kids[] = sprintf('%d 0 R', 5 + ($i * 2));
        }

        $objects[2] = sprintf(
            '<< /Type /Pages /Count %d /Kids [%s] >>',
            $pageCount,
            implode(' ', $kids)
        );

        $objects[3] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>';
        $objects[4] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>';

        foreach ($this->pages as $index => $content) {
            $pageObject    = 5 + ($index * 2);
            $contentObject = $pageObject + 1;

            $objects[$pageObject] = sprintf(
                '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.2f %.2f] '
                . '/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents %d 0 R >>',
                self::PAGE_WIDTH,
                self::PAGE_HEIGHT,
                $contentObject
            );

            $objects[$contentObject] = sprintf(
                "<< /Length %d >>\nstream\n%s\nendstream",
                strlen($content),
                $content
            );
        }

        ksort($objects);

        $pdf     = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n";
        $offsets = [];

        foreach ($objects as $number => $body) {
            $offsets[$number] = strlen($pdf);
            $pdf .= sprintf("%d 0 obj\n%s\nendobj\n", $number, $body);
        }

        $xrefOffset = strlen($pdf);
        $maxObject  = max(array_keys($objects));

        $pdf .= sprintf("xref\n0 %d\n0000000000 65535 f \n", $maxObject + 1);

        for ($i = 1; $i <= $maxObject; $i++) {
            $pdf .= isset($offsets[$i])
                ? sprintf("%010d 00000 n \n", $offsets[$i])
                : "0000000000 65535 f \n";
        }

        $pdf .= sprintf(
            "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF",
            $maxObject + 1,
            $xrefOffset
        );

        return $pdf;
    }
}
