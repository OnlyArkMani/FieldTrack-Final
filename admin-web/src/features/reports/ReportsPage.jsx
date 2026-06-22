import { useEffect, useRef, useState } from 'react';
import dayjs from 'dayjs';
import { Download, FileSpreadsheet, AlertCircle, Loader2 } from 'lucide-react';

import { api, apiErrorMessage } from '@/services/api/client';
import { useTeams } from '@/hooks/useTeams';
import PageHeader from '@/components/ui/PageHeader';
import Card, { CardHeader } from '@/components/ui/Card';
import Button from '@/components/ui/Button';
import { Input, Select } from '@/components/ui/Input';

const MAX_RANGE_DAYS = 31;
const POLL_INTERVAL_MS = 3000;
const POLL_MAX_TICKS = 20; // 20 × 3s = 60s timeout

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

export default function ReportsPage() {
  const today = dayjs().format('YYYY-MM-DD');
  const { data: teams = [] } = useTeams();
  const [type, setType] = useState('ATTENDANCE');
  const [format, setFormat] = useState('EXCEL');
  const [teamId, setTeamId] = useState('');
  const [startDate, setStartDate] = useState(dayjs().subtract(29, 'day').format('YYYY-MM-DD'));
  const [endDate, setEndDate] = useState(today);

  // phase: idle | generating | ready | failed
  const [phase, setPhase] = useState('idle');
  const [error, setError] = useState(null);
  const [reportId, setReportId] = useState(null);
  const [downloading, setDownloading] = useState(false);

  const pollRef = useRef(null);
  const clearPoll = () => {
    if (pollRef.current) {
      clearInterval(pollRef.current);
      pollRef.current = null;
    }
  };
  // Stop polling if the user navigates away mid-generation.
  useEffect(() => clearPoll, []);

  const noPdf = NO_PDF_TYPES.has(type);
  const formats = noPdf ? ALL_FORMATS.filter((f) => f.value !== 'PDF') : ALL_FORMATS;
  const teamRequired = TEAM_REQUIRED_TYPES.has(type);
  const teamMissing = teamRequired && !teamId;
  const isCompliance = type === 'GEOFENCE_COMPLIANCE';

  // Max end date = start + 31 days, never in the future.
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
    // Distance & Zone Time has no PDF — fall back to Excel if PDF was picked.
    if (NO_PDF_TYPES.has(value) && format === 'PDF') setFormat('EXCEL');
    resetResult();
  };

  const onStartChange = (value) => {
    setStartDate(value);
    const start = dayjs(value);
    const cap = capDate(value);
    if (dayjs(endDate).isAfter(cap) || dayjs(endDate).isBefore(start)) {
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
        // PROCESSING → keep polling
      } catch (err) {
        clearPoll();
        setPhase('failed');
        setError(apiErrorMessage(err));
      }
    }, POLL_INTERVAL_MS);
  };

  const generate = async () => {
    if (rangeTooLong || teamMissing) return;
    resetResult();
    setPhase('generating');
    try {
      const { data } = await api.post('/reports/generate', {
        type,
        format,
        filters: {
          start_date: startDate,
          end_date: endDate,
          ...(teamId ? { team_id: Number(teamId) } : {}),
        },
      });
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

  return (
    <div className="space-y-6">
      <PageHeader title="Reports" subtitle="Generate and download attendance, distance & zone reports" />

      <Card>
        <CardHeader title="Build a report" />
        <div className="flex flex-wrap items-end gap-3">
          <div className="w-56">
            <Select label="Report type" value={type} onChange={(e) => onTypeChange(e.target.value)} disabled={busy}>
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
          {teamRequired && (
            <div className="w-56">
              <Select
                label={<>Team <span className="text-danger">*</span></>}
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
          <div className="w-40">
            <Select label="Format" value={format} onChange={(e) => { setFormat(e.target.value); resetResult(); }} disabled={busy}>
              {formats.map((f) => (
                <option key={f.value} value={f.value}>{f.label}</option>
              ))}
            </Select>
          </div>
          <Button icon={FileSpreadsheet} onClick={generate} loading={busy} disabled={rangeTooLong || busy || teamMissing}>
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
        {isCompliance ? (
          <p className="mt-1 text-xs text-text-secondary">
            Shows whether employees visited their assigned zones, with time spent per zone.
            Requires a team. Available in Excel and CSV only.
          </p>
        ) : noPdf && (
          <p className="mt-1 text-xs text-text-secondary">
            Shows distance traveled and time spent in each geofence zone per employee per day.
            Available in Excel and CSV only.
          </p>
        )}
        {teamMissing && (
          <p className="mt-2 text-sm text-danger">Select a team to generate this report.</p>
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
