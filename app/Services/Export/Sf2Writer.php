<?php
declare(strict_types=1);

namespace App\Services\Export;

/**
 * Renders a DepEd School Form 2 (SF2) — Daily Attendance Report of Learners —
 * as a real .xlsx workbook, without any spreadsheet library.
 *
 * SF2 is a fixed form, not a table, so this writes the OOXML by hand: a header
 * block (School ID, School Year, Month, Name of School, Grade, Section), a
 * two-row column header (date numbers over day letters), the male and female
 * registers each followed by a per-day present count, a combined total, a short
 * legend, and the two certification lines. One mark sits in each learner/day
 * cell: blank for present, "x" for absent, and a shaded cell for tardy, exactly
 * as the form prescribes.
 *
 * The grid widens to however many class days the month had and lengthens to the
 * roster, so any section and month produce a correctly sized form.
 *
 * @see \App\Services\ReportService::schoolFormTwo for the data shape.
 */
final class Sf2Writer
{
    // Style indices into the cellXfs table built in styles().
    private const S_BODY      = 0;   // plain, left/top, no border
    private const S_TITLE     = 1;   // bold 14, centered
    private const S_SUBTITLE  = 2;   // italic 8, centered
    private const S_CELL      = 3;   // bordered, centered (a day mark)
    private const S_HEAD      = 4;   // bold bordered centered (day numbers/letters, labels)
    private const S_NAME      = 5;   // bordered, left (learner name)
    private const S_TARDY     = 6;   // bordered, centered, shaded (tardy)
    private const S_LABEL     = 7;   // bold, left, no border (field labels)
    private const S_VALUE     = 8;   // bordered, left (field values)
    private const S_ROWLABEL  = 9;   // bold bordered left (MALE/FEMALE/Combined)
    private const S_WRAP      = 10;  // bordered, left/top, wrapped (legend)
    private const S_CENTERB   = 11;  // bold centered, no border (certification name)
    private const S_CENTER    = 12;  // plain centered, no border (certification caption)

    /** @var array<string,array{0:mixed,1:int,2:string}> ref => [value, style, type] */
    private array $cells = [];

    /** @var list<string> */
    private array $merges = [];

    /** @var array<int,float> column index (1-based) => width */
    private array $colWidths = [];

    /** @var array<int,float> row number => height */
    private array $rowHeights = [];

    private int $maxRow = 1;
    private int $maxCol = 1;

    /**
     * @param array<string,mixed> $sf2 the 'sf2' payload from ReportService::schoolFormTwo
     */
    public static function build(array $sf2): string
    {
        return (new self())->render($sf2);
    }

    /** @param array<string,mixed> $sf2 */
    private function render(array $sf2): string
    {
        /** @var list<array{date:string,dom:int,dow:string}> $days */
        $days   = $sf2['days'] ?? [];
        $dayN   = count($days);
        $males  = $sf2['males'] ?? [];
        $females = $sf2['females'] ?? [];

        // Column map. Day columns run C .. C+dayN-1.
        $firstDay  = 3;
        $lastDay   = $firstDay + max($dayN, 1) - 1;
        $absentCol = $lastDay + 1;
        $tardyCol  = $lastDay + 2;
        $remCol    = $lastDay + 3;
        $lastCol   = max($remCol, 8);

        $this->colWidths[1] = 4.5;              // #
        $this->colWidths[2] = 34;               // name
        for ($c = $firstDay; $c <= $lastDay; $c++) {
            $this->colWidths[$c] = 3.6;
        }
        $this->colWidths[$absentCol] = 7.5;
        $this->colWidths[$tardyCol]  = 7.5;
        $this->colWidths[$remCol]    = 26;

        // ---- Title + subtitle ------------------------------------------------
        $this->put(1, 1, 'School Form 2 (SF2) Daily Attendance Report of Learners', self::S_TITLE);
        $this->merge(1, 1, 1, $lastCol);
        $this->rowHeights[1] = 22;
        $this->put(2, 1, '(This replaced Form 1, Form 2 & STS Form 4 - Absenteeism and Dropout Profile)', self::S_SUBTITLE);
        $this->merge(2, 1, 2, $lastCol);

        // ---- Header fields ---------------------------------------------------
        // Each field is a single bordered cell merged across several columns, so
        // the labels never collide with the narrow day columns beneath them.
        $grade = (string) ($sf2['grade'] ?? '');
        $sec   = (string) ($sf2['section'] ?? '');
        $mid   = min($lastCol, $firstDay + intdiv(max($dayN, 2), 2));

        $this->put(4, 1, 'School ID:  ' . (string) ($sf2['school_id'] ?? ''), self::S_VALUE);
        $this->merge(4, 1, 4, 2);
        $this->put(4, 3, 'School Year:  ' . (string) ($sf2['school_year'] ?? ''), self::S_VALUE);
        $this->merge(4, 3, 4, $mid);
        $this->put(4, $mid + 1, 'Report for the Month of:  ' . (string) ($sf2['month'] ?? ''), self::S_VALUE);
        $this->merge(4, $mid + 1, 4, $lastCol);

        $this->put(5, 1, 'Name of School:  ' . (string) ($sf2['school_name'] ?? ''), self::S_VALUE);
        $this->merge(5, 1, 5, 2);
        $this->put(5, 3, trim(sprintf('Grade:  %s        Section:  %s', $grade, $sec)), self::S_VALUE);
        $this->merge(5, 3, 5, $lastCol);

        // ---- Column header (rows 7-8) ---------------------------------------
        $hr1 = 7;
        $hr2 = 8;
        $this->put($hr1, 1, '#', self::S_HEAD);
        $this->merge($hr1, 1, $hr2, 1);
        $this->put($hr1, 2, "LEARNER'S NAME (Last, First, Middle)", self::S_HEAD);
        $this->merge($hr1, 2, $hr2, 2);

        foreach ($days as $i => $day) {
            $c = $firstDay + $i;
            $this->put($hr1, $c, (int) $day['dom'], self::S_HEAD);
            $this->put($hr2, $c, (string) $day['dow'], self::S_HEAD);
        }
        // Pad an empty day column if the month somehow had none, so the grid is valid.
        if ($dayN === 0) {
            $this->put($hr1, $firstDay, '', self::S_HEAD);
            $this->put($hr2, $firstDay, '', self::S_HEAD);
        }

        $this->put($hr1, $absentCol, 'Total for the Month', self::S_HEAD);
        $this->merge($hr1, $absentCol, $hr1, $tardyCol);
        $this->put($hr2, $absentCol, 'ABSENT', self::S_HEAD);
        $this->put($hr2, $tardyCol, 'TARDY', self::S_HEAD);
        $this->put($hr1, $remCol, 'REMARKS', self::S_HEAD);
        $this->merge($hr1, $remCol, $hr2, $remCol);
        $this->rowHeights[$hr1] = 15;
        $this->rowHeights[$hr2] = 15;

        // ---- Registers -------------------------------------------------------
        $row = $hr2 + 1;
        $row = $this->writeBlock($males, $row, $firstDay, $lastDay, $absentCol, $tardyCol, $remCol, $dayN);
        $row = $this->writeTotalRow('MALE  |  TOTAL Per Day', $sf2['male_totals'] ?? [], $row, $firstDay, $absentCol, $tardyCol, $remCol, $dayN);
        $row = $this->writeBlock($females, $row, $firstDay, $lastDay, $absentCol, $tardyCol, $remCol, $dayN);
        $row = $this->writeTotalRow('FEMALE  |  TOTAL Per Day', $sf2['female_totals'] ?? [], $row, $firstDay, $absentCol, $tardyCol, $remCol, $dayN);
        $row = $this->writeTotalRow('Combined TOTAL Per Day', $sf2['combined_totals'] ?? [], $row, $firstDay, $absentCol, $tardyCol, $remCol, $dayN);

        // ---- Legend + certification -----------------------------------------
        $row++;
        $this->put($row, 1, 'Codes:  blank = Present     x = Absent     shaded cell = Tardy', self::S_WRAP);
        $this->merge($row, 1, $row, $remCol);
        $row += 2;

        $this->put($row, 2, 'I certify that this is a true and correct report.', self::S_CENTER);
        $this->merge($row, 2, $row, 4);
        $row += 2;
        $this->put($row, 2, strtoupper((string) ($sf2['adviser'] ?? '')), self::S_CENTERB);
        $this->merge($row, 2, $row, 4);
        $this->put($row, 6, strtoupper((string) ($sf2['head'] ?? '')), self::S_CENTERB);
        $this->merge($row, 6, $row, 8);
        $row++;
        $this->put($row, 2, '(Signature of Teacher / Adviser over Printed Name)', self::S_CENTER);
        $this->merge($row, 2, $row, 4);
        $this->put($row, 6, '(Signature of School Head over Printed Name)', self::S_CENTER);
        $this->merge($row, 6, $row, 8);

        $this->maxCol = max($this->maxCol, $lastCol);

        return $this->pack();
    }

    /**
     * Write one register (male or female) and return the next free row.
     *
     * @param list<array{name:string,marks:list<string>,absent:int,tardy:int}> $block
     */
    private function writeBlock(array $block, int $row, int $firstDay, int $lastDay, int $absentCol, int $tardyCol, int $remCol, int $dayN): int
    {
        if ($block === []) {
            // One empty, bordered row keeps the register visible even when a
            // section has no learners of that sex.
            $this->put($row, 1, '', self::S_CELL);
            $this->put($row, 2, '', self::S_NAME);
            for ($c = $firstDay; $c <= $lastDay; $c++) {
                $this->put($row, $c, '', self::S_CELL);
            }
            $this->put($row, $absentCol, '', self::S_CELL);
            $this->put($row, $tardyCol, '', self::S_CELL);
            $this->put($row, $remCol, '', self::S_CELL);
            return $row + 1;
        }

        foreach ($block as $i => $e) {
            $this->put($row, 1, $i + 1, self::S_CELL);
            $this->put($row, 2, (string) $e['name'], self::S_NAME);

            $marks = $e['marks'] ?? [];
            for ($d = 0; $d < max($dayN, 1); $d++) {
                $c    = $firstDay + $d;
                $mark = $marks[$d] ?? '';
                if ($mark === 'T') {
                    $this->put($row, $c, '', self::S_TARDY);
                } elseif ($mark === 'x') {
                    $this->put($row, $c, 'x', self::S_CELL);
                } else {
                    $this->put($row, $c, '', self::S_CELL);
                }
            }

            $this->put($row, $absentCol, ((int) ($e['absent'] ?? 0)) ?: '', self::S_CELL);
            $this->put($row, $tardyCol, ((int) ($e['tardy'] ?? 0)) ?: '', self::S_CELL);
            $this->put($row, $remCol, '', self::S_CELL);
            $row++;
        }

        return $row;
    }

    /**
     * Write a "TOTAL Per Day" row.
     *
     * @param list<int> $totals
     */
    private function writeTotalRow(string $label, array $totals, int $row, int $firstDay, int $absentCol, int $tardyCol, int $remCol, int $dayN): int
    {
        $this->put($row, 1, $label, self::S_ROWLABEL);
        $this->merge($row, 1, $row, 2);

        for ($d = 0; $d < max($dayN, 1); $d++) {
            $c = $firstDay + $d;
            $this->put($row, $c, ($totals[$d] ?? 0) !== 0 ? (int) $totals[$d] : '', self::S_HEAD);
        }
        $this->put($row, $absentCol, '', self::S_HEAD);
        $this->put($row, $tardyCol, '', self::S_HEAD);
        $this->put($row, $remCol, '', self::S_HEAD);

        return $row + 1;
    }

    // ---- cell primitives ----------------------------------------------------

    private function put(int $row, int $col, mixed $value, int $style): void
    {
        $type = 'str';
        if (is_int($value) || is_float($value)) {
            $type = 'num';
        }
        $this->cells[$this->ref($row, $col)] = [$value, $style, $type];
        $this->maxRow = max($this->maxRow, $row);
        $this->maxCol = max($this->maxCol, $col);
    }

    private function merge(int $r1, int $c1, int $r2, int $c2): void
    {
        $this->merges[] = $this->ref($r1, $c1) . ':' . $this->ref($r2, $c2);
    }

    private function ref(int $row, int $col): string
    {
        return self::colName($col) . $row;
    }

    private static function colName(int $index): string
    {
        $name = '';
        while ($index > 0) {
            $rem   = ($index - 1) % 26;
            $name  = chr(65 + $rem) . $name;
            $index = intdiv($index - 1, 26);
        }
        return $name;
    }

    private static function escape(string $value): string
    {
        $clean = (string) preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F]/u', '', $value);
        return htmlspecialchars($clean, ENT_QUOTES | ENT_XML1 | ENT_SUBSTITUTE, 'UTF-8');
    }

    // ---- packaging ----------------------------------------------------------

    private function pack(): string
    {
        return Zip::create([
            '[Content_Types].xml'        => $this->contentTypes(),
            '_rels/.rels'                => $this->rootRels(),
            'docProps/app.xml'           => $this->appProps(),
            'docProps/core.xml'          => $this->coreProps(),
            'xl/workbook.xml'            => $this->workbook(),
            'xl/_rels/workbook.xml.rels' => $this->workbookRels(),
            'xl/styles.xml'              => $this->styles(),
            'xl/worksheets/sheet1.xml'   => $this->sheet(),
        ]);
    }

    private function sheet(): string
    {
        $xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">';

        // Columns
        $xml .= '<cols>';
        foreach ($this->colWidths as $c => $w) {
            $xml .= sprintf('<col min="%1$d" max="%1$d" width="%2$s" customWidth="1"/>', $c, rtrim(rtrim(number_format($w, 2, '.', ''), '0'), '.'));
        }
        $xml .= '</cols>';

        // Rows
        $xml .= '<sheetData>';
        for ($r = 1; $r <= $this->maxRow; $r++) {
            $cellsXml = '';
            for ($c = 1; $c <= $this->maxCol; $c++) {
                $ref = self::colName($c) . $r;
                if (!isset($this->cells[$ref])) {
                    continue;
                }
                [$value, $style, $type] = $this->cells[$ref];

                if ($value === '' || $value === null) {
                    $cellsXml .= sprintf('<c r="%s" s="%d"/>', $ref, $style);
                } elseif ($type === 'num') {
                    $cellsXml .= sprintf('<c r="%s" s="%d"><v>%s</v></c>', $ref, $style, (string) $value);
                } else {
                    $cellsXml .= sprintf(
                        '<c r="%s" s="%d" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>',
                        $ref,
                        $style,
                        self::escape((string) $value)
                    );
                }
            }

            $hgt = isset($this->rowHeights[$r])
                ? sprintf(' ht="%s" customHeight="1"', $this->rowHeights[$r])
                : '';
            $xml .= sprintf('<row r="%d"%s>%s</row>', $r, $hgt, $cellsXml);
        }
        $xml .= '</sheetData>';

        if ($this->merges !== []) {
            $xml .= sprintf('<mergeCells count="%d">', count($this->merges));
            foreach ($this->merges as $m) {
                $xml .= sprintf('<mergeCell ref="%s"/>', $m);
            }
            $xml .= '</mergeCells>';
        }

        return $xml . '</worksheet>';
    }

    private function styles(): string
    {
        $thin = '<left style="thin"><color auto="1"/></left><right style="thin"><color auto="1"/></right>'
              . '<top style="thin"><color auto="1"/></top><bottom style="thin"><color auto="1"/></bottom><diagonal/>';

        // Alignment fragments reused below.
        $alnCenter = '<alignment horizontal="center" vertical="center" wrapText="1"/>';
        $alnLeft   = '<alignment horizontal="left" vertical="center"/>';
        $alnTop    = '<alignment horizontal="left" vertical="top" wrapText="1"/>';
        $alnC      = '<alignment horizontal="center" vertical="center"/>';

        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            . '<fonts count="5">'
            . '<font><sz val="9"/><name val="Calibri"/></font>'
            . '<font><b/><sz val="9"/><name val="Calibri"/></font>'
            . '<font><b/><sz val="14"/><name val="Calibri"/></font>'
            . '<font><i/><sz val="8"/><name val="Calibri"/></font>'
            . '<font><b/><sz val="8"/><name val="Calibri"/></font>'
            . '</fonts>'
            . '<fills count="3">'
            . '<fill><patternFill patternType="none"/></fill>'
            . '<fill><patternFill patternType="gray125"/></fill>'
            . '<fill><patternFill patternType="solid"><fgColor rgb="FFBFBFBF"/><bgColor indexed="64"/></patternFill></fill>'
            . '</fills>'
            . '<borders count="2">'
            . '<border><left/><right/><top/><bottom/><diagonal/></border>'
            . '<border>' . $thin . '</border>'
            . '</borders>'
            . '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
            . '<cellXfs count="13">'
            // 0 body
            . '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1">' . $alnTop . '</xf>'
            // 1 title
            . '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1">' . $alnC . '</xf>'
            // 2 subtitle
            . '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1">' . $alnC . '</xf>'
            // 3 grid cell
            . '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1">' . $alnC . '</xf>'
            // 4 grid head bold
            . '<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">' . $alnCenter . '</xf>'
            // 5 name
            . '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1">' . $alnLeft . '</xf>'
            // 6 tardy
            . '<xf numFmtId="0" fontId="0" fillId="2" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1">' . $alnC . '</xf>'
            // 7 label bold
            . '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1">' . $alnLeft . '</xf>'
            // 8 value box
            . '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1">' . $alnLeft . '</xf>'
            // 9 row label bold
            . '<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">' . $alnLeft . '</xf>'
            // 10 wrap
            . '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1">' . $alnTop . '</xf>'
            // 11 center bold
            . '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1">' . $alnC . '</xf>'
            // 12 center plain
            . '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1">' . $alnC . '</xf>'
            . '</cellXfs>'
            . '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
            . '</styleSheet>';
    }

    private function contentTypes(): string
    {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            . '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            . '<Default Extension="xml" ContentType="application/xml"/>'
            . '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            . '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
            . '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
            . '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
            . '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
            . '</Types>';
    }

    private function rootRels(): string
    {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            . '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
            . '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
            . '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>'
            . '</Relationships>';
    }

    private function workbook(): string
    {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
            . ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            . '<sheets><sheet name="School Form 2 (SF2)" sheetId="1" r:id="rId1"/></sheets>'
            . '</workbook>';
    }

    private function workbookRels(): string
    {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            . '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
            . '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
            . '</Relationships>';
    }

    private function appProps(): string
    {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
            . '<Application>L-SIAMS</Application></Properties>';
    }

    private function coreProps(): string
    {
        $now = gmdate('Y-m-d\TH:i:s\Z');
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"'
            . ' xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/"'
            . ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
            . '<dc:title>School Form 2 (SF2)</dc:title>'
            . '<dc:creator>L-SIAMS</dc:creator>'
            . '<dcterms:created xsi:type="dcterms:W3CDTF">' . $now . '</dcterms:created>'
            . '</cp:coreProperties>';
    }
}
