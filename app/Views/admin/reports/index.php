<?php
/** @var App\Core\View $__view */

use App\Core\Auth;

$__view->extend('layouts.app');
$__view->start('content');

$isTeacher = Auth::isTeacher();
$base      = $isTeacher ? '/teacher' : '/admin';

/**
 * Which filter controls each report type actually uses. The server ignores
 * anything irrelevant, but hiding the unused fields stops an administrator
 * from believing a filter applied when it did not.
 */
$fieldsByType = [
    'student_summary'     => ['range', 'school_year_id', 'grade_level_id', 'section_id'],
    'daily'               => ['date', 'section_id', 'grade_level_id', 'subject_id', 'teacher_id', 'final_status'],
    'weekly'              => ['range', 'section_id', 'grade_level_id', 'subject_id', 'teacher_id'],
    'monthly'             => ['range', 'section_id', 'grade_level_id', 'subject_id', 'teacher_id'],
    'student'             => ['range', 'student_id'],
    'teacher'             => ['range', 'teacher_id'],
    'teacher_time_in'     => ['range', 'teacher_id'],
    // Naming a subject turns this into that subject day by day, so the date
    // range and the section both narrow it further.
    'subject'             => ['range', 'subject_id', 'grade_level_id', 'section_id'],
    'section_daily'       => ['date', 'section_id'],
    'section_summary'     => ['range', 'grade_level_id', 'section_id'],
    'section_comparison'  => ['range', 'grade_level_id'],
    'adviser'             => ['range', 'teacher_id'],
    'section_roster_rfid' => ['section_id'],
    'chronic_absence'     => ['range', 'grade_level_id', 'section_id', 'threshold'],
    'device_uptime'       => ['days', 'classroom_id'],
    'audit'               => ['range'],
    'security'            => ['range'],
];

/**
 * A one-line plain-English summary of each report, shown under the type
 * picker so an administrator can tell "Section Summary" from "Section
 * Comparison" without having to run both.
 */
$typeDescriptions = [
    'student_summary'     => 'Every student, one row each.',
    'daily'               => 'One day, all students.',
    'weekly'              => 'A week, day by day.',
    'monthly'             => 'A month, day by day.',
    'student'             => 'One student over a range.',
    'teacher'             => 'A teacher\'s sessions.',
    'teacher_time_in'     => 'When each teacher opened class, against the schedule.',
    'subject'             => 'One subject, day by day.',
    'section_daily'       => 'Printable roll-call sheet.',
    'section_summary'     => 'Per-section totals.',
    'section_comparison'  => 'Sections in a grade, compared.',
    'adviser'             => 'An adviser\'s advisory class.',
    'section_roster_rfid' => 'Who has an RFID card.',
    'chronic_absence'     => 'Students below a threshold.',
    'device_uptime'       => 'Terminal online reliability.',
    'audit'               => 'Who changed what, and when.',
    'security'            => 'Blocked scans, failed logins.',
];

/**
 * One tab per subject of a report - who or what it is about - so a teacher's
 * time-in and a student's absences are never in the same list. Each tab shows
 * its reports as buttons and only the filters the chosen report uses. The
 * first report of a tab is the one it opens on.
 */
$tabs = [
    'students' => ['Students', 'fa-user-graduate',   ['student_summary', 'daily', 'weekly', 'monthly', 'student', 'subject']],
    'teachers' => ['Teachers', 'fa-fingerprint'    , ['teacher_time_in', 'teacher', 'adviser']],
    'sections' => ['Sections', 'fa-clipboard-user',  ['section_daily', 'section_summary', 'section_comparison', 'section_roster_rfid', 'chronic_absence']],
    'system'   => ['System',   'fa-shield-halved',   ['device_uptime', 'audit', 'security']],
];

/** Short names for the report buttons; the full name is the button's title. */
$shortLabels = [
    'student_summary'     => 'Summary',
    'daily'               => 'Daily',
    'weekly'              => 'Weekly',
    'monthly'             => 'Monthly',
    'student'             => 'One student',
    'subject'             => 'By subject',
    'teacher_time_in'     => 'Time-in',
    'teacher'             => 'Sessions',
    'adviser'             => 'Adviser',
    'section_daily'       => 'Daily sheet',
    'section_summary'     => 'Summary',
    'section_comparison'  => 'Compare',
    'section_roster_rfid' => 'RFID roster',
    'chronic_absence'     => 'Chronic absence',
    'device_uptime'       => 'Terminals',
    'audit'               => 'Audit log',
    'security'            => 'Security log',
];

// Report types teachers may never run, even if they somehow reach this view.
$teacherHidden = ['audit', 'security', 'device_uptime'];

foreach ($tabs as $key => [$label, $icon, $tabTypes]) {
    $visible = array_values(array_filter(
        $tabTypes,
        fn ($t) => isset($types[$t]) && !($isTeacher && in_array($t, $teacherHidden, true))
    ));

    if ($visible === []) {
        unset($tabs[$key]);
    } else {
        $tabs[$key][2] = $visible;
    }
}

$currentYearRow = null;
foreach ($schoolYears as $year) {
    if ((int) $year['school_year_id'] === (int) $currentYear) {
        $currentYearRow = $year;
    }
}
?>

<?php $__view->include('partials.page-header', [
    'title'       => 'Reports',
    'subtitle'    => 'Pick a tab, pick a report, set the filters, then Preview. PDF and Excel exports carry every row; the on-screen preview is capped so the browser stays responsive.',
    'breadcrumbs' => [['Dashboard', $base], ['Reports', null]],
]); ?>

<style nonce="<?= e(csp_nonce()) ?>">
    /* ---- report tab switch --------------------------------------------- */
    .rtabs { display:flex; gap:.35rem; margin-bottom:1rem; background:var(--surface-alt); max-width:720px;
             padding:.3rem; border-radius:var(--radius-md, 10px); }
    .rtabs__btn { flex:1; border:0; background:transparent; cursor:pointer; padding:.55rem .6rem;
                  border-radius:var(--radius-sm, 8px); font-weight:600; font-size:.85rem;
                  color:var(--text-muted); display:flex; align-items:center; justify-content:center;
                  gap:.4rem; transition:background .12s, color .12s; }
    .rtabs__btn.is-active { background:var(--surface, #fff); color:var(--text); box-shadow:var(--shadow-sm, 0 1px 2px rgba(0,0,0,.08)); }

    .choice-grid { display:grid; grid-template-columns:repeat(2, 1fr); gap:.4rem; }
    .choice { border:1px solid var(--border, #d9dee6); background:var(--surface, #fff);
              border-radius:var(--radius-sm, 8px); padding:.6rem .5rem; cursor:pointer;
              font-weight:600; font-size:.83rem; color:var(--text); text-align:center;
              display:flex; align-items:center; justify-content:center; gap:.4rem;
              transition:border-color .12s, background .12s, color .12s; }
    .choice:hover { border-color:var(--primary, #1e5bd6); }
    .choice.is-active { border-color:var(--primary, #1e5bd6); background:var(--primary-050, rgba(30,91,214,.08));
                        color:var(--primary, #1e5bd6); }
    .choice i { font-size:.85rem; }

    .rtabs__btn i { font-size:.85rem; }
    .choice-grid--3 { grid-template-columns:repeat(3, 1fr); }
    .period-chips { display:flex; flex-wrap:wrap; gap:.3rem; margin-bottom:.45rem; }
    .period-chips button { border:1px solid var(--border, #d9dee6); background:var(--surface, #fff);
                           border-radius:999px; padding:.2rem .65rem; font-size:.75rem; cursor:pointer;
                           color:var(--text-muted); }
    .period-chips button:hover { border-color:var(--primary, #1e5bd6); color:var(--primary, #1e5bd6); }
</style>

<div class="rtabs" role="tablist">
    <?php $first = true; foreach ($tabs as $key => [$label, $icon, $tabTypes]): ?>
        <button type="button" class="rtabs__btn<?= $first ? ' is-active' : '' ?>" data-tab="<?= e($key) ?>"
                data-first="<?= e($tabTypes[0]) ?>" role="tab">
            <i class="fa-solid <?= e($icon) ?>"></i> <?= e($label) ?>
        </button>
    <?php $first = false; endforeach; ?>
</div>

<div class="grid" style="grid-template-columns:360px minmax(0, 1fr);align-items:start">
    <div>
        <div class="card">
            <div class="card__body">
                <form id="report-form">
                    <input type="hidden" name="type" id="r-type" value="<?= e(reset($tabs)[2][0]) ?>">

                    <div class="form-group">
                        <label>Report</label>
                        <?php $first = true; foreach ($tabs as $key => [$label, $icon, $tabTypes]): ?>
                            <div class="choice-grid choice-grid--3" data-tab-panel="<?= e($key) ?>"<?= $first ? '' : ' hidden' ?>>
                                <?php foreach ($tabTypes as $value): ?>
                                    <button type="button" class="choice" data-type="<?= e($value) ?>" title="<?= e($types[$value]) ?>">
                                        <?= e($shortLabels[$value] ?? $types[$value]) ?>
                                    </button>
                                <?php endforeach; ?>
                            </div>
                        <?php $first = false; endforeach; ?>
                        <span class="field-help" id="r-type-desc"></span>
                    </div>

                    <div class="form-group" data-field="date">
                        <label for="r-date">Date</label>
                        <input type="date" id="r-date" name="date" value="<?= e($defaultTo) ?>">
                    </div>

                    <div data-field="range">
                        <div class="period-chips" id="r-periods">
                            <button type="button" data-period="today">Today</button>
                            <button type="button" data-period="week">This week</button>
                            <button type="button" data-period="month">This month</button>
                            <?php if ($currentYearRow !== null): ?>
                                <button type="button" data-period="sy"
                                        data-start="<?= e($currentYearRow['start_date']) ?>"
                                        data-end="<?= e($currentYearRow['end_date']) ?>">School year</button>
                            <?php endif; ?>
                        </div>
                        <div class="form-grid">
                        <div class="form-group">
                            <label for="r-from">From</label>
                            <input type="date" id="r-from" name="date_from" value="<?= e($defaultFrom) ?>">
                        </div>
                        <div class="form-group">
                            <label for="r-to">To</label>
                            <input type="date" id="r-to" name="date_to" value="<?= e($defaultTo) ?>">
                        </div>
                        </div>
                    </div>

                    <div class="form-group" data-field="school_year_id">
                        <label for="r-year">School year</label>
                        <select id="r-year" name="school_year_id">
                            <option value="">All school years</option>
                            <?php foreach ($schoolYears as $year): ?>
                                <option value="<?= e($year['school_year_id']) ?>"
                                        <?= (int) $year['school_year_id'] === (int) $currentYear ? 'selected' : '' ?>>
                                    <?= e($year['year_label']) ?><?= (int) $year['is_current'] === 1 ? ' (current)' : '' ?>
                                </option>
                            <?php endforeach; ?>
                        </select>
                    </div>

                    <div class="form-group" data-field="grade_level_id">
                        <label for="r-grade">Grade level</label>
                        <select id="r-grade" name="grade_level_id">
                            <option value="">All grade levels</option>
                            <?php foreach ($gradeLevels as $grade): ?>
                                <option value="<?= e($grade['grade_level_id']) ?>"><?= e($grade['grade_level_name']) ?></option>
                            <?php endforeach; ?>
                        </select>
                    </div>

                    <div class="form-group" data-field="section_id">
                        <label for="r-section">Section</label>
                        <select id="r-section" name="section_id">
                            <option value="">All sections</option>
                            <?php foreach ($sections as $section): ?>
                                <option value="<?= e($section['section_id']) ?>" data-grade="<?= e($section['grade_level_id']) ?>">
                                    <?= e($section['section_code']) ?> — <?= e($section['section_name']) ?>
                                </option>
                            <?php endforeach; ?>
                        </select>
                    </div>

                    <div class="form-group" data-field="subject_id">
                        <label for="r-subject">Subject</label>
                        <select id="r-subject" name="subject_id">
                            <option value="">All subjects</option>
                            <?php foreach ($subjects as $subject): ?>
                                <option value="<?= e($subject['subject_id']) ?>">
                                    <?= e($subject['subject_code']) ?> — <?= e($subject['subject_name']) ?>
                                </option>
                            <?php endforeach; ?>
                        </select>
                    </div>

                    <div class="form-group" data-field="teacher_id">
                        <label for="r-teacher">Teacher</label>
                        <?php if ($isTeacher): ?>
                            <input type="text" value="Your own records only" readonly>
                            <span class="field-help">A teacher report is always scoped to you, whatever the form says.</span>
                        <?php else: ?>
                            <select id="r-teacher" name="teacher_id">
                                <option value="">All teachers</option>
                                <?php foreach ($teachers as $teacher): ?>
                                    <option value="<?= e($teacher['teacher_id']) ?>">
                                        <?= e($teacher['last_name']) ?>, <?= e($teacher['first_name']) ?>
                                    </option>
                                <?php endforeach; ?>
                            </select>
                        <?php endif; ?>
                    </div>

                    <div class="form-group" data-field="classroom_id">
                        <label for="r-classroom">Classroom</label>
                        <select id="r-classroom" name="classroom_id">
                            <option value="">All classrooms</option>
                            <?php foreach ($classrooms as $classroom): ?>
                                <option value="<?= e($classroom['classroom_id']) ?>">
                                    <?= e($classroom['room_number']) ?><?php if (!empty($classroom['building'])): ?> — <?= e($classroom['building']) ?><?php endif; ?>
                                </option>
                            <?php endforeach; ?>
                        </select>
                    </div>

                    <div class="form-group" data-field="student_id">
                        <label for="r-student-search">Student</label>
                        <input type="search" id="r-student-search" placeholder="Search by name or student number"
                               autocomplete="off">
                        <input type="hidden" name="student_id" id="r-student">
                        <div class="typeahead" id="r-student-results" hidden></div>
                        <span class="field-help" id="r-student-chosen">No student selected.</span>
                    </div>

                    <div class="form-group" data-field="final_status">
                        <label for="r-status">Final status</label>
                        <select id="r-status" name="final_status">
                            <option value="">Any status</option>
                            <?php foreach (['Present', 'Late', 'Left Early', 'Incomplete', 'Excused', 'Absent'] as $status): ?>
                                <option value="<?= e($status) ?>"><?= e($status) ?></option>
                            <?php endforeach; ?>
                        </select>
                    </div>

                    <div class="form-group" data-field="threshold">
                        <label for="r-threshold">Attendance threshold</label>
                        <input type="number" id="r-threshold" name="threshold" min="1" max="100" step="0.5" placeholder="80">
                        <span class="field-help">Students below this percentage are listed. Defaults to the system setting.</span>
                    </div>

                    <div class="form-group" data-field="days">
                        <label for="r-days">Window</label>
                        <select id="r-days" name="days">
                            <option value="7">Last 7 days</option>
                            <option value="14">Last 14 days</option>
                            <option value="30">Last 30 days</option>
                        </select>
                    </div>

                    <div class="flex gap-1">
                        <button type="submit" class="btn btn-primary" style="flex:1">
                            <i class="fa-solid fa-magnifying-glass"></i> Preview
                        </button>
                        <button type="button" class="btn btn-secondary" id="r-reset" title="Clear every filter back to its default">
                            <i class="fa-solid fa-rotate-left"></i> Reset
                        </button>
                    </div>

                    <?php if (!$isTeacher): ?>
                        <div data-tab-panel="students">
                            <button type="button" class="btn btn-secondary btn-block mt-1" id="r-cards">
                                <i class="fa-solid fa-id-card"></i> Printable student cards (PDF)
                            </button>
                            <p class="field-help mt-1">
                                One page per student with their day-by-day attendance, for the
                                section, grade or student chosen above.
                            </p>
                        </div>
                    <?php endif; ?>
                </form>
            </div>
        </div>
    </div>

    <div>
        <div class="card" id="preview-card">
            <div class="card__header">
                <div>
                    <h2 class="card__title" id="preview-title">Preview</h2>
                    <div class="text-xs text-muted" id="preview-subtitle">Choose a report and press Preview.</div>
                </div>
                <div class="flex gap-1" id="export-buttons">
                    <label class="checkbox" style="margin-right:.5rem">
                        <input type="checkbox" id="r-save" checked>
                        <span class="text-xs">Keep in history</span>
                    </label>
                    <button class="btn btn-secondary btn-sm" data-export="pdf"><i class="fa-solid fa-file-pdf"></i> PDF</button>
                    <button class="btn btn-secondary btn-sm" data-export="xlsx"><i class="fa-solid fa-file-excel"></i> Excel</button>
                </div>
            </div>

            <div class="card__body" id="preview-stats" hidden></div>

            <div class="card__body--flush">
                <div id="preview-body">
                    <?php $__view->include('partials.empty-state', [
                        'icon'  => 'fa-file-lines',
                        'title' => 'Nothing previewed yet',
                        'text'  => 'Reports are generated from live data — nothing here is cached.',
                    ]); ?>
                </div>
            </div>
        </div>

        <?php if (!$isTeacher): ?>
            <div class="card">
                <div class="card__header">
                    <h2 class="card__title">Recently generated</h2>
                    <span class="text-xs text-muted">Report files live outside the web root and are served through an access check</span>
                </div>
                <div class="card__body--flush">
                    <?php if ($history === []): ?>
                        <?php $__view->include('partials.empty-state', [
                            'icon'  => 'fa-clock-rotate-left',
                            'title' => 'No saved reports yet',
                        ]); ?>
                    <?php else: ?>
                        <div class="table-wrap">
                            <table class="data">
                                <thead>
                                <tr><th>Report</th><th>Format</th><th class="numeric">Rows</th><th>Generated by</th><th>When</th><th></th></tr>
                                </thead>
                                <tbody>
                                <?php foreach ($history as $report): ?>
                                    <tr>
                                        <td class="cell-stack">
                                            <span class="cell-primary"><?= e($report['report_name']) ?></span>
                                            <span class="cell-muted"><?= e($types[$report['report_type']] ?? $report['report_type']) ?></span>
                                        </td>
                                        <td><span class="badge badge-neutral"><?= e(strtoupper((string) $report['format'])) ?></span></td>
                                        <td class="numeric"><?= e(number_format((int) $report['row_count'])) ?></td>
                                        <td class="text-sm"><?= e($report['full_name']) ?></td>
                                        <td class="nowrap text-sm"><?= e(time_ago($report['created_at'])) ?></td>
                                        <td class="nowrap">
                                            <a class="btn btn-ghost btn-sm" href="<?= e($base) ?>/reports/<?= e($report['report_id']) ?>/download">
                                                <i class="fa-solid fa-download"></i> Download
                                            </a>
                                        </td>
                                    </tr>
                                <?php endforeach; ?>
                                </tbody>
                            </table>
                        </div>
                    <?php endif; ?>
                </div>
            </div>
        <?php endif; ?>
    </div>
</div>

<?php
$__view->stop();
$__view->start('scripts');
?>
<script nonce="<?= e(csp_nonce()) ?>">
(function () {
    const LS   = window.LSIAMS;
    const BASE = <?= json_js($base) ?>;

    const FIELDS = <?= json_js($fieldsByType) ?>;
    const DESCS  = <?= json_js($typeDescriptions) ?>;

    // Colour the Status / Standing column exactly as the dashboards do, so a
    // preview reads at a glance instead of as a wall of grey text. Anything not
    // a known label falls back to a neutral badge rather than being mis-coloured.
    const STATUS_BADGE = {
        'Present':           'badge-success',
        'Late':              'badge-warning',
        'Left Early':        'badge-warning',
        'Incomplete':        'badge-warning',
        'Absent':            'badge-danger',
        'Excused':           'badge-info',
        'Official Business': 'badge-info',
        // Student-summary standings.
        'Good':              'badge-success',
        'At risk':           'badge-warning',
        'Chronic':           'badge-danger',
        'No data':           'badge-neutral',
    };

    function cellHtml(cell, isBadge) {
        const text = cell === null ? '—' : String(cell);
        if (isBadge && cell !== null && text !== '' && text !== '—') {
            return '<td><span class="badge ' + (STATUS_BADGE[text] || 'badge-neutral') + '">'
                + LS.util.escape(text) + '</span></td>';
        }
        return '<td>' + LS.util.escape(text) + '</td>';
    }

    /* ==================================================================== *
     *  Shared preview + export
     * ==================================================================== */
    function renderPreview(data) {
        document.getElementById('preview-title').textContent    = data.title;
        document.getElementById('preview-subtitle').textContent = data.subtitle;

        const stats = document.getElementById('preview-stats');
        const entries = Object.entries(data.statistics || {});

        if (entries.length === 0) {
            stats.hidden = true;
        } else {
            stats.hidden = false;
            stats.innerHTML = '<div class="grid grid--6">' + entries.map(([key, value]) =>
                '<div style="padding:.55rem .7rem;background:var(--surface-alt);border-radius:var(--radius-sm)">'
                + '<div class="text-xs text-muted">' + LS.util.escape(key.replace(/_/g, ' ')) + '</div>'
                + '<div class="fw-600" style="font-size:18px">' + LS.util.escape(String(value)) + '</div></div>').join('')
                + '</div>';
        }

        const body = document.getElementById('preview-body');

        if (!data.rows || data.rows.length === 0) {
            body.innerHTML = '<div class="empty-state">'
                + '<div class="empty-state__icon"><i class="fa-solid fa-inbox"></i></div>'
                + '<div class="empty-state__title">No rows matched these filters</div>'
                + '<div class="empty-state__text">The report is still exportable — it will simply be empty.</div></div>';
            return;
        }

        // Colour any column whose header is "Status" or "Standing".
        const badgeCols = data.headers.reduce((acc, h, i) => {
            const key = String(h).trim().toLowerCase();
            if (key === 'status' || key === 'standing') acc.push(i);
            return acc;
        }, []);

        let html = '<div class="table-wrap" style="max-height:560px;overflow:auto"><table class="data"><thead><tr>'
            + data.headers.map((header) => '<th>' + LS.util.escape(header) + '</th>').join('')
            + '</tr></thead><tbody>'
            + data.rows.map((row) => '<tr>'
                + row.map((cell, i) => cellHtml(cell, badgeCols.indexOf(i) !== -1)).join('')
                + '</tr>').join('')
            + '</tbody></table></div>';

        if (data.truncated) {
            html += '<div class="alert alert-info" style="margin:1rem">'
                + '<span class="alert__icon"><i class="fa-solid fa-circle-info"></i></span>'
                + '<div class="alert__body">Showing the first ' + data.rows.length + ' of '
                + data.total_rows.toLocaleString() + ' rows. The export contains all of them.</div></div>';
        }

        body.innerHTML = html;
    }

    // Back to an empty preview, so totals from one report are never left
    // sitting above another report or an error.
    const EMPTY_PREVIEW = document.getElementById('preview-body').innerHTML;

    function resetPreview() {
        document.getElementById('preview-title').textContent    = 'Preview';
        document.getElementById('preview-subtitle').textContent = 'Choose a report and press Preview.';
        document.getElementById('preview-stats').hidden = true;
    }

    async function runPreview(params, button) {
        LS.util.setBusy(button, true, 'Building…');

        const body = document.getElementById('preview-body');
        body.innerHTML = '<div style="padding:1rem">'
            + '<div class="skeleton skeleton--row"></div><div class="skeleton skeleton--row"></div>'
            + '<div class="skeleton skeleton--row"></div></div>';

        try {
            const response = await LS.http.post(BASE + '/reports/preview', params);
            renderPreview(response.data);
        } catch (error) {
            resetPreview();
            // Say what is missing ("Select a teacher for this report.") rather
            // than the bare "Validation failed." the response leads with.
            const messages = error.errors ? Object.values(error.errors).flat() : [];
            body.innerHTML = '<div class="alert alert-danger" style="margin:1rem">'
                + LS.util.escape(messages.length ? messages.join(' ') : (error.message || 'Could not build this report.'))
                + '</div>';
        } finally {
            LS.util.setBusy(button, false);
        }
    }

    function runExport(params, format) {
        const fields = Object.assign({}, params, {
            format: format,
            save:   document.getElementById('r-save').checked ? '1' : '0',
            _csrf:  LS.config.csrfToken,
        });

        const post = document.createElement('form');
        post.method = 'post';
        post.action = BASE + '/reports/generate';
        post.style.display = 'none';

        Object.entries(fields).forEach(([key, value]) => {
            if (value === '' || value === null || value === undefined) return;
            const input = document.createElement('input');
            input.type  = 'hidden';
            input.name  = key;
            input.value = value;
            post.appendChild(input);
        });

        document.body.appendChild(post);
        post.submit();
        setTimeout(() => post.remove(), 1000);
    }

    // Post the given params to any download endpoint (used for the per-student
    // card booklet, which is a plain PDF stream rather than a built report).
    function postDownload(action, params) {
        const fields = Object.assign({}, params, { _csrf: LS.config.csrfToken });

        const post = document.createElement('form');
        post.method = 'post';
        post.action = BASE + action;
        post.style.display = 'none';

        Object.entries(fields).forEach(([key, value]) => {
            if (value === '' || value === null || value === undefined) return;
            const input = document.createElement('input');
            input.type  = 'hidden';
            input.name  = key;
            input.value = value;
            post.appendChild(input);
        });

        document.body.appendChild(post);
        post.submit();
        setTimeout(() => post.remove(), 1000);
    }

    /* ==================================================================== *
     *  Tabs and report buttons
     * ==================================================================== */
    const form    = document.getElementById('report-form');
    const type    = document.getElementById('r-type');
    const desc    = document.getElementById('r-type-desc');
    const grade   = document.getElementById('r-grade');
    const section = document.getElementById('r-section');

    function chooseType(value) {
        if (type.value !== value) {
            resetPreview();
            document.getElementById('preview-body').innerHTML = EMPTY_PREVIEW;
        }
        type.value = value;
        form.querySelectorAll('[data-type]').forEach((b) => b.classList.toggle('is-active', b.dataset.type === value));
        syncFields();
    }

    document.querySelectorAll('.rtabs__btn').forEach((btn) => btn.addEventListener('click', function () {
        document.querySelectorAll('.rtabs__btn').forEach((b) => b.classList.toggle('is-active', b === btn));
        document.querySelectorAll('[data-tab-panel]').forEach((panel) => {
            panel.hidden = panel.dataset.tabPanel !== btn.dataset.tab;
        });
        chooseType(btn.dataset.first);
    }));

    form.addEventListener('click', function (event) {
        const btn = event.target.closest('[data-type]');
        if (btn) chooseType(btn.dataset.type);
    });

    function syncFields() {
        const wanted = FIELDS[type.value] || [];
        desc.textContent = DESCS[type.value] || '';

        form.querySelectorAll('[data-field]').forEach((node) => {
            const show = wanted.indexOf(node.dataset.field) !== -1;
            node.hidden = !show;

            if (!show) {
                node.querySelectorAll('select, input').forEach((input) => {
                    if (input.type === 'date' || input.type === 'checkbox') return;
                    input.value = '';
                });
            }
        });
    }

    /* ---- period shortcuts fill From / To -------------------------------- */
    const pad = (n) => String(n).padStart(2, '0');
    const fmt = (d) => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());

    document.getElementById('r-periods').addEventListener('click', function (event) {
        const btn = event.target.closest('[data-period]');
        if (!btn) return;

        const today = new Date();
        let from = fmt(today), to = fmt(today);

        if (btn.dataset.period === 'week') {
            const d = new Date();
            d.setDate(d.getDate() - (d.getDay() + 6) % 7);   // back to Monday
            from = fmt(d);
        } else if (btn.dataset.period === 'month') {
            from = fmt(new Date(today.getFullYear(), today.getMonth(), 1));
        } else if (btn.dataset.period === 'sy') {
            // The year in progress counts up to today.
            from = btn.dataset.start;
            to   = to > btn.dataset.end ? btn.dataset.end : to;
        }

        document.getElementById('r-from').value = from;
        document.getElementById('r-to').value   = to;
    });

    function syncSections() {
        const gradeId = grade.value;
        Array.from(section.options).forEach((option) => {
            if (option.value === '') return;
            option.hidden = gradeId !== '' && option.dataset.grade !== gradeId;
        });
        if (section.selectedOptions[0] && section.selectedOptions[0].hidden) section.value = '';
    }

    grade.addEventListener('change', syncSections);

    document.getElementById('r-reset').addEventListener('click', function () {
        const current = type.value;
        form.reset();
        type.value = current;
        const studentChosen  = document.getElementById('r-student');
        const studentLabel   = document.getElementById('r-student-chosen');
        const studentResults = document.getElementById('r-student-results');
        if (studentChosen)  studentChosen.value = '';
        if (studentResults) studentResults.hidden = true;
        if (studentLabel) {
            studentLabel.textContent = 'No student selected.';
            studentLabel.className = 'field-help';
        }
        syncSections();
        syncFields();
    });

    /* ---- student typeahead ---------------------------------------------- */
    (function () {
        const search  = document.getElementById('r-student-search');
        const chosen  = document.getElementById('r-student');
        const results = document.getElementById('r-student-results');
        const label   = document.getElementById('r-student-chosen');

        search.addEventListener('input', LS.util.debounce(async function () {
            const query = search.value.trim();
            if (query.length < 2) { results.hidden = true; return; }
            try {
                const response = await LS.http.get(BASE + '/reports/students/search', { q: query });
                const rows = response.data.rows || [];
                results.innerHTML = rows.length === 0
                    ? '<div class="typeahead__empty">No match.</div>'
                    : rows.map((row) =>
                        '<button type="button" class="typeahead__item" data-id="' + row.student_id + '">'
                        + '<span>' + LS.util.escape(row.name) + '</span>'
                        + '<span class="text-xs text-muted mono">' + LS.util.escape(row.student_number)
                        + ' · ' + LS.util.escape(row.section_code || '—') + '</span></button>').join('');
                results.hidden = false;
            } catch (error) { results.hidden = true; }
        }, 300));

        results.addEventListener('click', function (event) {
            const item = event.target.closest('[data-id]');
            if (!item) return;
            chosen.value = item.dataset.id;
            label.textContent = 'Selected: ' + item.textContent.trim();
            label.className = 'field-help text-success';
            search.value = '';
            results.hidden = true;
        });
    })();

    form.addEventListener('submit', function (event) {
        event.preventDefault();
        runPreview(LS.util.formData(form), form.querySelector('[type=submit]'));
    });

    const cardsBtn = document.getElementById('r-cards');
    if (cardsBtn) {
        // The card booklet is always the per-student expansion; it takes the
        // same scope (year, grade, section or one student) as the form.
        cardsBtn.addEventListener('click', () => postDownload('/reports/student-cards', LS.util.formData(form)));
    }

    document.getElementById('export-buttons').addEventListener('click', function (event) {
        const button = event.target.closest('[data-export]');
        if (!button) return;
        runExport(LS.util.formData(form), button.dataset.export);
    });

    chooseType(type.value);
})();
</script>
<?php $__view->stop(); ?>
