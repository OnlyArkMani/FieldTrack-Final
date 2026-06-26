// Quick report generation: scroll to "Generate Report" section at the bottom.
// Employee is pre-selected from the page context — no picker needed.

import { useEffect, useRef, useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import dayjs from 'dayjs';
import {
  ArrowLeft,
  ChevronLeft,
  ChevronRight,
  Power,
  Pencil,
  ShieldAlert,
  ShieldCheck,
  MapPin,
  Download,
  Loader2,
  AlertCircle,
} from 'lucide-react';

import {
  useEmployee,
  useAttendanceSummary,
  useSetEmployeeStatus,
  useGpsIntegrity,
} from '@/hooks/useEmployees';
import { useTeams } from '@/hooks/useTeams';
import { api, apiErrorMessage } from '@/services/api/client';

import Card, { CardHeader } from '@/components/ui/Card';
import Button from '@/components/ui/Button';
import Badge from '@/components/ui/Badge';
import Avatar from '@/components/ui/Avatar';
import Spinner from '@/components/ui/Spinner';
import EmployeeFormModal from './EmployeeFormModal';
import TrailReplayModal from '@/features/map/TrailReplayModal';

const STATUS_COLOR = {
  PRESENT: 'var(--ft-status-active)',
  ABSENT: 'var(--ft-status-danger)',
  HALF_DAY: 'var(--ft-status-battery)',
};

function AttendanceCalendar({ summary, cursor }) {
  const byDate = {};
  for (const d of summary?.days || []) byDate[d.date] = d.status;

  const start = cursor.startOf('month');
  const daysInMonth = cursor.daysInMonth();
  const leadingBlanks = start.day(); // 0=Sun

  const cells = [];
  for (let i = 0; i < leadingBlanks; i += 1) cells.push(null);
  for (let day = 1; day <= daysInMonth; day += 1) {
    const date = start.date(day).format('YYYY-MM-DD');
    cells.push({ day, status: byDate[date] });
  }

  return (
    <div>
      <div className="mb-2 grid grid-cols-7 gap-1 text-center text-xs text-text-secondary">
        {['S', 'M', 'T', 'W', 'T', 'F', 'S'].map((d, i) => (
          <div key={i}>{d}</div>
        ))}
      </div>
      <div className="grid grid-cols-7 gap-1">
        {cells.map((c, i) =>
          c === null ? (
            <div key={i} />
          ) : (
            <div
              key={i}
              className="flex aspect-square items-center justify-center rounded-btn text-sm"
              style={{
                background: c.status ? `${STATUS_COLOR[c.status]}26` : 'var(--ft-surface)',
                color: c.status ? STATUS_COLOR[c.status] : 'var(--ft-text-secondary)',
                border: '1px solid var(--ft-border)',
              }}
              title={c.status || 'No record'}
            >
              {c.day}
            </div>
          ),
        )}
      </div>
      <div className="mt-4 flex flex-wrap gap-4 text-xs">
        {[
          ['Present', STATUS_COLOR.PRESENT],
          ['Half day', STATUS_COLOR.HALF_DAY],
          ['Absent', STATUS_COLOR.ABSENT],
        ].map(([label, color]) => (
          <span key={label} className="flex items-center gap-1.5 text-text-secondary">
            <span className="h-3 w-3 rounded" style={{ background: color }} />
            {label}
          </span>
        ))}
      </div>
    </div>
  );
}

export default function EmployeeDetailPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { data: employee, isLoading } = useEmployee(id);
  const { data: teams = [] } = useTeams();
  const setActive = useSetEmployeeStatus();
  const [cursor, setCursor] = useState(dayjs());
  const [editing, setEditing] = useState(false);
  const [trailOpen, setTrailOpen] = useState(false);

  const summaryQ = useAttendanceSummary(id, cursor.year(), cursor.month() + 1);

  if (isLoading || !employee) {
    return <Spinner label="Loading employee…" className="py-20" />;
  }

  const toggle = async () => {
    try {
      await setActive.mutateAsync({ id: employee.id, isActive: !employee.is_active });
    } catch (err) {
      alert(apiErrorMessage(err));
    }
  };

  const teamName = teams.find((t) => t.id === employee.team_id)?.name;

  return (
    <div className="space-y-6">
      <button
        onClick={() => navigate('/employees')}
        className="flex items-center gap-1 text-sm text-text-secondary hover:text-text-primary"
      >
        <ArrowLeft className="h-4 w-4" /> Back to employees
      </button>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <Card className="lg:col-span-1">
          <div className="flex items-center gap-3">
            <Avatar name={employee.name} src={employee.profile_photo_url} size={56} />
            <div className="min-w-0">
              <h2 className="truncate text-lg font-semibold text-text-primary">
                {employee.name}
              </h2>
              <div className="mt-1 flex items-center gap-2">
                <Badge status={employee.live?.live_status || 'OFFLINE'} />
                <span className="text-xs text-text-secondary">
                  {employee.role?.toLowerCase()}
                </span>
              </div>
            </div>
          </div>

          <dl className="mt-5 space-y-3 text-sm">
            <Row label="Email" value={employee.email} />
            <Row label="Phone" value={employee.phone || '—'} />
            <Row label="Team" value={teamName || '—'} />
            <Row
              label="Account"
              value={employee.is_active ? 'Active' : 'Inactive'}
            />
          </dl>

          <div className="mt-5 flex gap-2">
            <Button variant="outline" icon={Pencil} onClick={() => setEditing(true)} className="flex-1">
              Edit
            </Button>
            <Button
              variant={employee.is_active ? 'danger' : 'primary'}
              icon={Power}
              loading={setActive.isPending}
              onClick={toggle}
              className="flex-1"
            >
              {employee.is_active ? 'Deactivate' : 'Activate'}
            </Button>
          </div>

          <Button
            variant="secondary"
            icon={MapPin}
            onClick={() => setTrailOpen(true)}
            className="mt-2 w-full"
          >
            View Trail
          </Button>
        </Card>

        <Card className="lg:col-span-2">
          <CardHeader
            title="Attendance history"
            action={
              <div className="flex items-center gap-2">
                <Button size="sm" variant="ghost" icon={ChevronLeft}
                  onClick={() => setCursor((c) => c.subtract(1, 'month'))} />
                <span className="text-sm font-medium text-text-primary">
                  {cursor.format('MMMM YYYY')}
                </span>
                <Button size="sm" variant="ghost" icon={ChevronRight}
                  onClick={() => setCursor((c) => c.add(1, 'month'))} />
              </div>
            }
          />
          {summaryQ.isLoading ? (
            <Spinner label="Loading…" className="py-10" />
          ) : (
            <>
              <div className="mb-4 grid grid-cols-3 gap-3">
                <Mini label="Present" value={summaryQ.data?.days_present ?? 0} color={STATUS_COLOR.PRESENT} />
                <Mini label="Half day" value={summaryQ.data?.days_half ?? 0} color={STATUS_COLOR.HALF_DAY} />
                <Mini label="Absent" value={summaryQ.data?.days_absent ?? 0} color={STATUS_COLOR.ABSENT} />
              </div>
              <AttendanceCalendar summary={summaryQ.data} cursor={cursor} />
            </>
          )}
        </Card>
      </div>

      <GpsIntegrityCard employeeId={employee.id} />

      <EmployeeReportCard employeeId={employee.id} employeeName={employee.name} />

      <EmployeeFormModal open={editing} employee={employee} onClose={() => setEditing(false)} />
      <TrailReplayModal
        open={trailOpen}
        onClose={() => setTrailOpen(false)}
        employee={employee}
      />
    </div>
  );
}

// ── Employee report generation ────────────────────────────────────────────
const REPORT_TYPES = [
  { value: 'ATTENDANCE', label: 'Attendance' },
  { value: 'DISTANCE', label: 'Distance' },
  { value: 'DISTANCE_ZONES', label: 'Distance & Zone Time' },
];

const REPORT_FORMATS = [
  { value: 'CSV', label: 'CSV' },
  { value: 'EXCEL', label: 'Excel' },
  { value: 'PDF', label: 'PDF' },
];

// Tabular-only types can't generate PDF.
const NO_PDF_TYPES = new Set(['DISTANCE_ZONES']);

const MAX_RANGE_DAYS = 31;
const POLL_INTERVAL_MS = 3000;
const POLL_MAX_TICKS = 20; // 20 × 3s = 60s

function getWeekRange() {
  const start = dayjs().startOf('week').add(1, 'day'); // Monday
  return { start: start.format('YYYY-MM-DD'), end: dayjs().format('YYYY-MM-DD') };
}
function getMonthRange() {
  return { start: dayjs().startOf('month').format('YYYY-MM-DD'), end: dayjs().format('YYYY-MM-DD') };
}

function EmployeeReportCard({ employeeId, employeeName }) {
  const today = dayjs().format('YYYY-MM-DD');

  const [reportType, setReportType] = useState('ATTENDANCE');
  const [format, setFormat] = useState('CSV');
  const [period, setPeriod] = useState('month'); // 'week' | 'month' | 'custom'
  const [startDate, setStartDate] = useState(getMonthRange().start);
  const [endDate, setEndDate] = useState(today);

  // phase: idle | generating | ready | failed
  const [phase, setPhase] = useState('idle');
  const [error, setError] = useState(null);
  const [reportId, setReportId] = useState(null);
  const pollRef = useRef(null);

  const clearPoll = () => {
    if (pollRef.current) { clearInterval(pollRef.current); pollRef.current = null; }
  };
  useEffect(() => () => clearPoll(), []);

  const noPdf = NO_PDF_TYPES.has(reportType);
  const formats = noPdf ? REPORT_FORMATS.filter((f) => f.value !== 'PDF') : REPORT_FORMATS;
  // If current format is PDF and we switch to a no-pdf type, fall back to CSV.
  useEffect(() => {
    if (noPdf && format === 'PDF') setFormat('CSV');
  }, [noPdf, format]);

  const onPeriodChange = (p) => {
    setPeriod(p);
    if (p === 'week') {
      const r = getWeekRange();
      setStartDate(r.start);
      setEndDate(r.end);
    } else if (p === 'month') {
      const r = getMonthRange();
      setStartDate(r.start);
      setEndDate(r.end);
    }
    setPhase('idle');
    setError(null);
  };

  const capDate = (start) => {
    const plus = dayjs(start).add(MAX_RANGE_DAYS, 'day');
    return plus.isAfter(dayjs(today)) ? dayjs(today) : plus;
  };
  const maxEnd = capDate(startDate).format('YYYY-MM-DD');
  const rangeTooLong = dayjs(endDate).diff(dayjs(startDate), 'day') > MAX_RANGE_DAYS;

  const pollStatus = (id, fmt) => {
    let ticks = 0;
    pollRef.current = setInterval(async () => {
      ticks += 1;
      try {
        const { data } = await api.get(`/reports/${id}/status`);
        if (data.status === 'READY') {
          clearPoll();
          // Trigger auto-download.
          triggerDownload(id, fmt);
          setPhase('ready');
        } else if (data.status === 'FAILED' || data.status === 'EXPIRED') {
          clearPoll();
          setPhase('failed');
          setError(data.error || 'Report generation failed.');
        } else if (ticks >= POLL_MAX_TICKS) {
          clearPoll();
          setPhase('failed');
          setError('Taking too long, try a smaller date range.');
        }
      } catch (err) {
        clearPoll();
        setPhase('failed');
        setError(apiErrorMessage(err));
      }
    }, POLL_INTERVAL_MS);
  };

  const triggerDownload = async (id, fmt) => {
    try {
      const resp = await api.get(`/reports/${id}/download`, { responseType: 'blob' });
      const cd = resp.headers['content-disposition'] || '';
      const match = /filename="?([^"]+)"?/.exec(cd);
      const ext = fmt === 'EXCEL' ? 'xlsx' : fmt.toLowerCase();
      const safeName = employeeName.replace(/\s+/g, '_');
      const filename = match ? match[1] : `report_${safeName}_${startDate}_${endDate}.${ext}`;
      const url = URL.createObjectURL(resp.data);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      a.click();
      URL.revokeObjectURL(url);
    } catch {
      // Silent — download failed, user can retry via the Download button.
    }
  };

  const generate = async () => {
    if (rangeTooLong) return;
    clearPoll();
    setPhase('generating');
    setError(null);
    setReportId(null);
    try {
      const { data } = await api.post('/reports/generate', {
        type: reportType,
        format,
        filters: {
          start_date: startDate,
          end_date: endDate,
          user_id: employeeId,
        },
      });
      setReportId(data.report_id);
      pollStatus(data.report_id, format);
    } catch (err) {
      setPhase('failed');
      setError(apiErrorMessage(err));
    }
  };

  const retry = () => {
    setPhase('idle');
    setError(null);
    generate();
  };

  const downloadAgain = () => reportId && triggerDownload(reportId, format);

  const busy = phase === 'generating';
  const canGenerate = !rangeTooLong && !busy;

  return (
    <div
      style={{
        borderLeft: '4px solid var(--ft-primary)',
        background: 'var(--ft-card)',
        borderRadius: 'var(--ft-radius)',
        padding: '1.25rem 1.5rem',
        boxShadow: 'var(--ft-shadow)',
      }}
    >
      <div className="mb-4">
        <h3 className="text-base font-semibold text-text-primary">Generate Report</h3>
        <p className="text-xs text-text-secondary">
          Employee: <span className="font-medium">{employeeName}</span>
        </p>
      </div>

      {/* Report type */}
      <div className="mb-3">
        <label className="mb-1 block text-xs font-medium text-text-secondary">Type</label>
        <div className="flex flex-wrap gap-2">
          {REPORT_TYPES.map((rt) => (
            <button
              key={rt.value}
              type="button"
              disabled={busy}
              onClick={() => { setReportType(rt.value); setPhase('idle'); setError(null); }}
              className="rounded-btn border px-3 py-1.5 text-sm transition-colors disabled:opacity-50"
              style={{
                background: reportType === rt.value ? 'var(--ft-primary)' : 'var(--ft-surface)',
                color: reportType === rt.value ? '#fff' : 'var(--ft-text-secondary)',
                borderColor: reportType === rt.value ? 'var(--ft-primary)' : 'var(--ft-border)',
                fontWeight: reportType === rt.value ? 600 : 400,
              }}
            >
              {rt.label}
            </button>
          ))}
        </div>
      </div>

      {/* Period */}
      <div className="mb-3">
        <label className="mb-1 block text-xs font-medium text-text-secondary">Period</label>
        <div className="flex flex-wrap gap-2">
          {['week', 'month', 'custom'].map((p) => (
            <button
              key={p}
              type="button"
              disabled={busy}
              onClick={() => onPeriodChange(p)}
              className="rounded-btn border px-3 py-1.5 text-sm transition-colors disabled:opacity-50"
              style={{
                background: period === p ? 'var(--ft-secondary)' : 'var(--ft-surface)',
                color: period === p ? '#fff' : 'var(--ft-text-secondary)',
                borderColor: period === p ? 'var(--ft-secondary)' : 'var(--ft-border)',
                fontWeight: period === p ? 600 : 400,
              }}
            >
              {p === 'week' ? 'This week' : p === 'month' ? 'This month' : 'Custom'}
            </button>
          ))}
        </div>

        {period === 'custom' && (
          <div className="mt-3 flex flex-wrap gap-3">
            <div>
              <label className="mb-1 block text-xs text-text-secondary">From</label>
              <input
                type="date"
                max={today}
                value={startDate}
                disabled={busy}
                onChange={(e) => {
                  setStartDate(e.target.value);
                  const cap = capDate(e.target.value);
                  if (dayjs(endDate).isAfter(cap)) setEndDate(cap.format('YYYY-MM-DD'));
                  setPhase('idle');
                }}
                className="h-9 rounded-btn border border-border bg-surface px-3 text-sm text-text-primary focus:border-primary focus:outline-none disabled:opacity-50"
              />
            </div>
            <div>
              <label className="mb-1 block text-xs text-text-secondary">To</label>
              <input
                type="date"
                min={startDate}
                max={maxEnd}
                value={endDate}
                disabled={busy}
                onChange={(e) => { setEndDate(e.target.value); setPhase('idle'); }}
                className="h-9 rounded-btn border border-border bg-surface px-3 text-sm text-text-primary focus:border-primary focus:outline-none disabled:opacity-50"
              />
            </div>
          </div>
        )}
        {rangeTooLong && (
          <p className="mt-1.5 text-xs text-danger">Date range cannot exceed 31 days.</p>
        )}
      </div>

      {/* Format */}
      <div className="mb-5">
        <label className="mb-1 block text-xs font-medium text-text-secondary">Format</label>
        <div className="flex flex-wrap gap-2">
          {formats.map((f) => (
            <button
              key={f.value}
              type="button"
              disabled={busy}
              onClick={() => { setFormat(f.value); setPhase('idle'); setError(null); }}
              className="rounded-btn border px-3 py-1.5 text-sm transition-colors disabled:opacity-50"
              style={{
                background: format === f.value ? 'var(--ft-primary)' : 'var(--ft-surface)',
                color: format === f.value ? '#fff' : 'var(--ft-text-secondary)',
                borderColor: format === f.value ? 'var(--ft-primary)' : 'var(--ft-border)',
                fontWeight: format === f.value ? 600 : 400,
              }}
            >
              {f.label}
            </button>
          ))}
        </div>
      </div>

      {/* Generate button */}
      <button
        type="button"
        onClick={generate}
        disabled={!canGenerate}
        className="flex items-center gap-2 rounded-btn px-5 py-2.5 text-sm font-semibold text-white transition-opacity disabled:opacity-50"
        style={{ background: canGenerate ? 'var(--ft-primary)' : 'var(--ft-border)' }}
      >
        {busy ? (
          <>
            <Loader2 className="h-4 w-4 animate-spin" />
            Generating…
          </>
        ) : (
          <>
            <Download className="h-4 w-4" />
            Generate &amp; Download
          </>
        )}
      </button>

      {/* Status feedback */}
      {phase === 'ready' && (
        <div className="mt-3 flex items-center gap-3">
          <span className="text-sm font-medium" style={{ color: 'var(--ft-status-active)' }}>
            ✓ Downloaded successfully.
          </span>
          <button
            type="button"
            onClick={downloadAgain}
            className="text-xs text-text-secondary underline hover:text-text-primary"
          >
            Download again
          </button>
        </div>
      )}

      {phase === 'failed' && error && (
        <div className="mt-3 flex items-start gap-2" style={{ color: 'var(--ft-status-danger)' }}>
          <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
          <div>
            <p className="text-sm">{error}</p>
            <button
              type="button"
              onClick={retry}
              className="mt-1 text-xs underline hover:opacity-80"
            >
              Retry
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

function GpsIntegrityCard({ employeeId }) {
  const { data, isLoading } = useGpsIntegrity(employeeId);
  const flaggedToday = data?.flagged_today;
  const detections = data?.detections ?? 0;
  const points = data?.points || [];

  return (
    <Card>
      <CardHeader
        title="GPS integrity"
        subtitle={`Mock-location detections · last ${data?.window_days ?? 7} days`}
        action={
          isLoading ? null : flaggedToday ? (
            <Badge color="var(--ft-status-danger)">
              <span className="flex items-center gap-1">
                <ShieldAlert className="h-3.5 w-3.5" /> Flagged today
              </span>
            </Badge>
          ) : detections > 0 ? (
            <Badge color="var(--ft-status-battery)">Past detections</Badge>
          ) : (
            <Badge color="var(--ft-status-active)">
              <span className="flex items-center gap-1">
                <ShieldCheck className="h-3.5 w-3.5" /> Clean
              </span>
            </Badge>
          )
        }
      />

      {isLoading ? (
        <Spinner label="Loading…" className="py-8" />
      ) : (
        <>
          <div className="mb-4 grid grid-cols-2 gap-3">
            <Mini
              label="Detections (7d)"
              value={detections}
              color={detections > 0 ? 'var(--ft-status-danger)' : 'var(--ft-status-active)'}
            />
            <Mini
              label="Today"
              value={flaggedToday ? 'Yes' : 'No'}
              color={flaggedToday ? 'var(--ft-status-danger)' : 'var(--ft-status-active)'}
            />
          </div>

          {points.length === 0 ? (
            <div className="rounded-btn border border-border p-6 text-center text-sm text-text-secondary">
              No mock-GPS activity detected. Location data looks authentic.
            </div>
          ) : (
            <ol className="space-y-2">
              {points.map((p, i) => (
                <li
                  key={i}
                  className="flex items-center gap-3 rounded-btn border border-border p-3"
                >
                  <span
                    className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full border"
                    style={{ borderColor: 'var(--ft-status-danger)' }}
                  >
                    <MapPin className="h-4 w-4" style={{ color: 'var(--ft-status-danger)' }} />
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-sm font-medium text-text-primary">
                      {dayjs(p.timestamp).format('MMM D, YYYY · HH:mm')}
                    </div>
                    <div className="truncate text-xs text-text-secondary">
                      {p.lat.toFixed(5)}, {p.lng.toFixed(5)}
                      {p.accuracy != null ? ` · ±${Math.round(p.accuracy)}m` : ''}
                      {p.battery_level != null ? ` · ${p.battery_level}% battery` : ''}
                    </div>
                  </div>
                </li>
              ))}
            </ol>
          )}
        </>
      )}
    </Card>
  );
}

function Row({ label, value }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <dt className="text-text-secondary">{label}</dt>
      <dd className="truncate text-right font-medium text-text-primary">{value}</dd>
    </div>
  );
}

function Mini({ label, value, color }) {
  return (
    <div className="rounded-btn border border-border p-3 text-center">
      <div className="text-xl font-bold" style={{ color }}>
        {value}
      </div>
      <div className="text-xs text-text-secondary">{label}</div>
    </div>
  );
}
