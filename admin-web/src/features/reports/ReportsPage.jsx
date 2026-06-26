// Individual employee reports: use the
// "By employee" toggle in the filter row.
// Scope options: All employees | By team | By employee.
// When "By employee" is chosen an autocomplete search box appears;
// the selected employee's id is forwarded as user_id in the POST body.

import { useCallback, useEffect, useRef, useState } from 'react';
import dayjs from 'dayjs';
import { Download, FileSpreadsheet, AlertCircle, Loader2, X } from 'lucide-react';

import { api, apiErrorMessage } from '@/services/api/client';
import { useTeams } from '@/hooks/useTeams';
import PageHeader from '@/components/ui/PageHeader';
import Card, { CardHeader } from '@/components/ui/Card';
import Button from '@/components/ui/Button';
import { Input, Select } from '@/components/ui/Input';

const MAX_RANGE_DAYS = 31;
const POLL_INTERVAL_MS = 3000;
const POLL_MAX_TICKS = 20; // 20 × 3s = 60s timeout
const SEARCH_DEBOUNCE_MS = 300;

const REPORT_TYPES = [
  { value: 'ATTENDANCE', label: 'Attendance' },
  { value: 'DISTANCE', label: 'Distance' },
  { value: 'DISTANCE_ZONES', label: 'Distance & Zone Time' },
  { value: 'GEOFENCE_COMPLIANCE', label: 'Geofence Compliance' },
];

const ALL_FORMATS = [
  { value: 'EXCEL', label: 'Excel' },
  { value: 'CSV', label: 'CSV' },
  { value: 'PDF', label: 'PDF' },
];

// Report types that don't support PDF (tabular-only, server-enforced too).
const NO_PDF_TYPES = new Set(['DISTANCE_ZONES', 'GEOFENCE_COMPLIANCE']);
// Report types that REQUIRE a team_id filter.
const TEAM_REQUIRED_TYPES = new Set(['GEOFENCE_COMPLIANCE']);

// ── Employee autocomplete ─────────────────────────────────────────────────
function EmployeeSearch({ value, onChange, disabled }) {
  // value = { id, name, team_name } | null
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [open, setOpen] = useState(false);
  const [searching, setSearching] = useState(false);
  const debounceRef = useRef(null);
  const containerRef = useRef(null);

  // Close dropdown on outside click.
  useEffect(() => {
    const handler = (e) => {
      if (containerRef.current && !containerRef.current.contains(e.target)) {
        setOpen(false);
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  const search = useCallback(async (q) => {
    if (!q.trim()) { setResults([]); setOpen(false); return; }
    setSearching(true);
    try {
      const { data } = await api.get('/employees', { params: { search: q.trim(), limit: 20 } });
      setResults(data.items ?? data ?? []);
      setOpen(true);
    } catch {
      setResults([]);
    } finally {
      setSearching(false);
    }
  }, []);

  const onInput = (e) => {
    const q = e.target.value;
    setQuery(q);
    clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => search(q), SEARCH_DEBOUNCE_MS);
  };

  const pick = (emp) => {
    onChange(emp);
    setQuery('');
    setOpen(false);
    setResults([]);
  };

  const clear = () => {
    onChange(null);
    setQuery('');
    setResults([]);
  };

  const initial = (name) => (name ? name.charAt(0).toUpperCase() : '?');

  if (value) {
    // Show selected employee chip with clear button.
    return (
      <div
        className="flex h-9 items-center gap-2 rounded-btn border border-border bg-surface px-3 text-sm"
        style={{ minWidth: '13rem' }}
      >
        <span
          className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-semibold text-white"
          style={{ background: 'var(--ft-primary)' }}
        >
          {initial(value.name)}
        </span>
        <span className="min-w-0 flex-1 truncate font-medium text-text-primary">
          {value.name}
          {value.team_name && (
            <span className="ml-1 font-normal text-text-secondary">· {value.team_name}</span>
          )}
        </span>
        <button
          type="button"
          onClick={clear}
          disabled={disabled}
          className="shrink-0 text-text-secondary hover:text-text-primary"
          aria-label="Clear employee selection"
        >
          <X className="h-3.5 w-3.5" />
        </button>
      </div>
    );
  }

  return (
    <div ref={containerRef} className="relative" style={{ minWidth: '13rem' }}>
      <div className="relative">
        <input
          type="text"
          placeholder="Search employee…"
          value={query}
          onChange={onInput}
          onFocus={() => results.length && setOpen(true)}
          disabled={disabled}
          className="h-9 w-full rounded-btn border border-border bg-surface px-3 text-sm text-text-primary placeholder:text-text-secondary focus:border-primary focus:outline-none disabled:opacity-50"
        />
        {searching && (
          <Loader2 className="absolute right-2.5 top-2 h-4 w-4 animate-spin text-text-secondary" />
        )}
      </div>
      {open && results.length > 0 && (
        <ul
          className="absolute z-50 mt-1 max-h-52 w-full overflow-auto rounded-btn border border-border bg-card shadow-lg"
        >
          {results.map((emp) => (
            <li key={emp.id}>
              <button
                type="button"
                className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm hover:bg-surface"
                onMouseDown={(e) => { e.preventDefault(); pick(emp); }}
              >
                <span
                  className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-semibold text-white"
                  style={{ background: 'var(--ft-primary)' }}
                >
                  {initial(emp.name)}
                </span>
                <div className="min-w-0">
                  <div className="truncate font-medium text-text-primary">{emp.name}</div>
                  {emp.team_name && (
                    <div className="truncate text-xs text-text-secondary">{emp.team_name}</div>
                  )}
                </div>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// ── Scope toggle ──────────────────────────────────────────────────────────
function ScopeToggle({ scope, onChange, disabled }) {
  const opts = [
    { value: 'all', label: 'All employees' },
    { value: 'team', label: 'By team' },
    { value: 'employee', label: 'By employee' },
  ];
  return (
    <div className="flex items-center gap-3 flex-wrap">
      {opts.map((o) => (
        <label key={o.value} className="flex cursor-pointer items-center gap-1.5 text-sm select-none">
          <input
            type="radio"
            name="scope"
            value={o.value}
            checked={scope === o.value}
            onChange={() => onChange(o.value)}
            disabled={disabled}
            className="accent-primary"
          />
          <span className={scope === o.value ? 'font-medium text-text-primary' : 'text-text-secondary'}>
            {o.label}
          </span>
        </label>
      ))}
    </div>
  );
}

// ── Main page ─────────────────────────────────────────────────────────────
export default function ReportsPage() {
  const today = dayjs().format('YYYY-MM-DD');
  const { data: teams = [] } = useTeams();
  const [type, setType] = useState('ATTENDANCE');
  const [format, setFormat] = useState('EXCEL');

  // Scope: 'all' | 'team' | 'employee'
  const [scope, setScope] = useState('all');
  const [teamId, setTeamId] = useState('');
  const [employee, setEmployee] = useState(null); // { id, name, team_name }

  const [startDate, setStartDate] = useState(dayjs().subtract(29, 'day').format('YYYY-MM-DD'));
  const [endDate, setEndDate] = useState(today);

  // phase: idle | generating | ready | failed
  const [phase, setPhase] = useState('idle');
  const [error, setError] = useState(null);
  const [reportId, setReportId] = useState(null);
  const [downloading, setDownloading] = useState(false);

  const pollRef = useRef(null);
  const clearPoll = () => {
    if (pollRef.current) { clearInterval(pollRef.current); pollRef.current = null; }
  };
  useEffect(() => clearPoll, []);

  const noPdf = NO_PDF_TYPES.has(type);
  const formats = noPdf ? ALL_FORMATS.filter((f) => f.value !== 'PDF') : ALL_FORMATS;

  // For GEOFENCE_COMPLIANCE, force scope to 'team'.
  const forceTeam = TEAM_REQUIRED_TYPES.has(type);

  const effectiveScope = forceTeam ? 'team' : scope;

  const teamMissing = effectiveScope === 'team' && !teamId;
  const employeeMissing = effectiveScope === 'employee' && !employee;
  const isCompliance = type === 'GEOFENCE_COMPLIANCE';

  const capDate = (start) => {
    const plus = dayjs(start).add(MAX_RANGE_DAYS, 'day');
    return plus.isAfter(dayjs(today)) ? dayjs(today) : plus;
  };
  const maxEnd = capDate(startDate).format('YYYY-MM-DD');
  const rangeTooLong = dayjs(endDate).diff(dayjs(startDate), 'day') > MAX_RANGE_DAYS;

  const resetResult = () => {
    clearPoll();
    setPhase('idle');
    setError(null);
    setReportId(null);
  };

  const onTypeChange = (value) => {
    setType(value);
    if (NO_PDF_TYPES.has(value) && format === 'PDF') setFormat('EXCEL');
    // GEOFENCE_COMPLIANCE forces team scope — reset to team if needed.
    if (TEAM_REQUIRED_TYPES.has(value) && scope !== 'team') setScope('team');
    resetResult();
  };

  const onScopeChange = (s) => {
    setScope(s);
    setTeamId('');
    setEmployee(null);
    resetResult();
  };

  const onStartChange = (value) => {
    setStartDate(value);
    const cap = capDate(value);
    if (dayjs(endDate).isAfter(cap) || dayjs(endDate).isBefore(dayjs(value))) {
      setEndDate(cap.format('YYYY-MM-DD'));
    }
    resetResult();
  };

  const pollStatus = (id) => {
    let ticks = 0;
    pollRef.current = setInterval(async () => {
      ticks += 1;
      try {
        const { data } = await api.get(`/reports/${id}/status`);
        if (data.status === 'READY') {
          clearPoll();
          setPhase('ready');
        } else if (data.status === 'FAILED' || data.status === 'EXPIRED') {
          clearPoll();
          setPhase('failed');
          setError(data.error || 'Report generation failed. Please retry.');
        } else if (ticks >= POLL_MAX_TICKS) {
          clearPoll();
          setPhase('failed');
          setError('Still generating after 60s. Please retry.');
        }
      } catch (err) {
        clearPoll();
        setPhase('failed');
        setError(apiErrorMessage(err));
      }
    }, POLL_INTERVAL_MS);
  };

  const generate = async () => {
    if (rangeTooLong || teamMissing || employeeMissing) return;
    resetResult();
    setPhase('generating');
    try {
      const filters = { start_date: startDate, end_date: endDate };
      if (effectiveScope === 'team' && teamId) filters.team_id = Number(teamId);
      if (effectiveScope === 'employee' && employee) filters.user_id = employee.id;

      const { data } = await api.post('/reports/generate', { type, format, filters });
      setReportId(data.report_id);
      pollStatus(data.report_id);
    } catch (err) {
      setPhase('failed');
      setError(apiErrorMessage(err));
    }
  };

  const downloadFile = async () => {
    if (!reportId) return;
    setDownloading(true);
    try {
      const resp = await api.get(`/reports/${reportId}/download`, { responseType: 'blob' });
      const cd = resp.headers['content-disposition'] || '';
      const match = /filename="?([^"]+)"?/.exec(cd);
      const ext = format === 'EXCEL' ? 'xlsx' : format.toLowerCase();
      const filename = match ? match[1] : `report_${startDate}_${endDate}.${ext}`;
      const url = URL.createObjectURL(resp.data);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      a.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      setError(apiErrorMessage(err));
    } finally {
      setDownloading(false);
    }
  };

  const busy = phase === 'generating';
  const canGenerate = !rangeTooLong && !busy && !teamMissing && !employeeMissing;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Reports"
        subtitle="Generate and download attendance, distance & zone reports"
      />

      <Card>
        <CardHeader title="Build a report" />

        {/* Row 1: Report type + format */}
        <div className="flex flex-wrap items-end gap-3">
          <div className="w-56">
            <Select
              label="Report type"
              value={type}
              onChange={(e) => onTypeChange(e.target.value)}
              disabled={busy}
            >
              {REPORT_TYPES.map((t) => (
                <option key={t.value} value={t.value}>{t.label}</option>
              ))}
            </Select>
          </div>
          <div className="w-44">
            <Input
              label="Start date"
              type="date"
              max={today}
              value={startDate}
              onChange={(e) => onStartChange(e.target.value)}
              disabled={busy}
            />
          </div>
          <div className="w-44">
            <Input
              label="End date"
              type="date"
              min={startDate}
              max={maxEnd}
              value={endDate}
              onChange={(e) => { setEndDate(e.target.value); resetResult(); }}
              disabled={busy}
            />
          </div>
          <div className="w-40">
            <Select
              label="Format"
              value={format}
              onChange={(e) => { setFormat(e.target.value); resetResult(); }}
              disabled={busy}
            >
              {formats.map((f) => (
                <option key={f.value} value={f.value}>{f.label}</option>
              ))}
            </Select>
          </div>
        </div>

        {/* Row 2: Scope toggle + conditional team/employee picker */}
        <div className="mt-4 space-y-3">
          {!forceTeam && (
            <ScopeToggle scope={scope} onChange={onScopeChange} disabled={busy} />
          )}

          {effectiveScope === 'team' && (
            <div className="w-56">
              <Select
                label={
                  <>
                    Team{' '}
                    {forceTeam && <span className="text-danger">*</span>}
                  </>
                }
                value={teamId}
                onChange={(e) => { setTeamId(e.target.value); resetResult(); }}
                disabled={busy}
              >
                <option value="">Select a team…</option>
                {teams.map((t) => (
                  <option key={t.id} value={t.id}>{t.name}</option>
                ))}
              </Select>
            </div>
          )}

          {effectiveScope === 'employee' && (
            <div>
              <label className="mb-1 block text-xs font-medium text-text-secondary">
                Employee
              </label>
              <EmployeeSearch
                value={employee}
                onChange={(emp) => { setEmployee(emp); resetResult(); }}
                disabled={busy}
              />
            </div>
          )}
        </div>

        {/* Actions */}
        <div className="mt-4 flex flex-wrap items-center gap-3">
          <Button
            icon={FileSpreadsheet}
            onClick={generate}
            loading={busy}
            disabled={!canGenerate}
          >
            Generate
          </Button>
          <Button
            variant="outline"
            icon={Download}
            onClick={downloadFile}
            loading={downloading}
            disabled={phase !== 'ready'}
          >
            Download
          </Button>
        </div>

        <p className="mt-2 text-xs italic text-text-secondary">Max 31 days per report.</p>

        {isCompliance && (
          <p className="mt-1 text-xs text-text-secondary">
            Shows whether employees visited their assigned zones, with time spent per zone.
            Requires a team. Available in Excel and CSV only.
          </p>
        )}
        {!isCompliance && noPdf && (
          <p className="mt-1 text-xs text-text-secondary">
            Shows distance traveled and time spent in each geofence zone per employee per day.
            Available in Excel and CSV only.
          </p>
        )}

        {teamMissing && (
          <p className="mt-2 text-sm text-danger">Select a team to generate this report.</p>
        )}
        {employeeMissing && (
          <p className="mt-2 text-sm text-danger">Search and select an employee to generate this report.</p>
        )}
        {rangeTooLong && (
          <p className="mt-2 text-sm text-danger">Please select a date range of 31 days or less.</p>
        )}
      </Card>

      {phase === 'generating' && (
        <Card>
          <div className="flex items-center gap-3 text-text-secondary">
            <Loader2 className="h-5 w-5 animate-spin text-primary" />
            <span>Generating your report… this can take a few seconds.</span>
          </div>
        </Card>
      )}

      {phase === 'ready' && (
        <Card>
          <div className="flex items-center justify-between gap-3">
            <div className="flex items-center gap-3">
              <FileSpreadsheet className="h-5 w-5 text-status-active" />
              <span className="font-medium text-text-primary">Report ready to download.</span>
            </div>
            <Button icon={Download} onClick={downloadFile} loading={downloading}>
              Download
            </Button>
          </div>
        </Card>
      )}

      {phase === 'failed' && error && (
        <Card>
          <div className="flex items-start gap-3 text-danger">
            <AlertCircle className="mt-0.5 h-5 w-5 shrink-0" />
            <div>
              <p className="font-medium">{error}</p>
              <Button variant="outline" size="sm" className="mt-3" onClick={generate}>
                Retry
              </Button>
            </div>
          </div>
        </Card>
      )}
    </div>
  );
}
