import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exceptions.dart';
import '../data/report_downloader.dart';
import '../data/report_repository.dart';
import '../models/report_models.dart';

/// Generation lifecycle for the reports screen.
enum ReportPhase { configuring, generating, ready, failed }

const _pollInterval = Duration(seconds: 3);
const _timeout = Duration(seconds: 60);

class ReportUiState {
  const ReportUiState({
    this.type = ReportType.attendance,
    this.format = ReportFormat.pdf,
    this.range,
    required this.month,
    this.teamId,
    this.phase = ReportPhase.configuring,
    this.error,
    this.file,
    this.timedOut = false,
    this.savedToDevice = false,
  });

  final ReportType type;
  final ReportFormat format;
  final DateTimeRange? range; // attendance / distance
  final DateTime month; // team report (1st of month)
  final int? teamId; // supervisor team selection
  final ReportPhase phase;
  final String? error;
  final File? file; // mobile only — null on web (browser-downloaded instead)
  final bool timedOut;
  final bool savedToDevice; // web: file was pushed to the browser's downloads

  bool get isTeamReport => type == ReportType.team;

  ReportUiState copyWith({
    ReportType? type,
    ReportFormat? format,
    DateTimeRange? range,
    DateTime? month,
    int? teamId,
    bool clearTeam = false,
    ReportPhase? phase,
    String? error,
    bool clearError = false,
    File? file,
    bool clearFile = false,
    bool? timedOut,
    bool? savedToDevice,
  }) =>
      ReportUiState(
        type: type ?? this.type,
        format: format ?? this.format,
        range: range ?? this.range,
        month: month ?? this.month,
        teamId: clearTeam ? null : (teamId ?? this.teamId),
        phase: phase ?? this.phase,
        error: clearError ? null : (error ?? this.error),
        file: clearFile ? null : (file ?? this.file),
        timedOut: timedOut ?? this.timedOut,
        savedToDevice: savedToDevice ?? this.savedToDevice,
      );
}

class ReportNotifier extends Notifier<ReportUiState> {
  // Cancels stale poll loops: each generate() bumps this; a loop bails the
  // moment its id no longer matches (new run, or reset).
  int _runId = 0;

  @override
  ReportUiState build() {
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day);
    return ReportUiState(
      range: DateTimeRange(start: end.subtract(const Duration(days: 29)), end: end),
      month: DateTime(now.year, now.month, 1),
    );
  }

  ReportRepository get _repo => ref.read(reportRepositoryProvider);

  // ── Configuration setters (reset any finished/failed result) ──────────
  void setType(ReportType t) {
    // Zone Report is CSV/Excel only — drop PDF if it was selected.
    final fmt = (!t.supportsPdf && state.format == ReportFormat.pdf)
        ? ReportFormat.excel
        : state.format;
    state = state.copyWith(
        type: t, format: fmt, phase: ReportPhase.configuring, clearFile: true, clearError: true);
  }
  void setFormat(ReportFormat f) =>
      state = state.copyWith(format: f, phase: ReportPhase.configuring, clearFile: true, clearError: true);
  void setRange(DateTimeRange r) =>
      state = state.copyWith(range: r, phase: ReportPhase.configuring, clearFile: true, clearError: true);
  void setMonth(DateTime m) => state = state.copyWith(
      month: DateTime(m.year, m.month, 1),
      phase: ReportPhase.configuring,
      clearFile: true,
      clearError: true);
  void setTeam(int? id) => state = state.copyWith(
      teamId: id, clearTeam: id == null, phase: ReportPhase.configuring, clearFile: true, clearError: true);

  void reset() {
    _runId++; // cancel any in-flight poll
    state = state.copyWith(
        phase: ReportPhase.configuring, clearFile: true, clearError: true, timedOut: false);
  }

  // ── Generate + poll ───────────────────────────────────────────────────
  Future<void> generate() async {
    if (state.isTeamReport && state.teamId == null) {
      state = state.copyWith(phase: ReportPhase.failed, error: 'Select a team first');
      return;
    }

    final runId = ++_runId;
    state = state.copyWith(
        phase: ReportPhase.generating,
        clearError: true,
        clearFile: true,
        timedOut: false,
        savedToDevice: false);

    try {
      final reportId = await _repo.generate(
        type: state.type,
        format: state.format,
        filters: _buildFilters(),
      );

      final deadline = DateTime.now().add(_timeout);
      while (_runId == runId) {
        await Future.delayed(_pollInterval);
        if (_runId != runId) return; // superseded / reset

        final ReportStatusResult st;
        try {
          st = await _repo.status(reportId);
        } catch (e) {
          state = state.copyWith(
              phase: ReportPhase.failed, error: _msg(e, 'Could not check report status.'));
          return;
        }

        if (st.status == ReportJobStatus.ready) {
          await _downloadAndFinish(reportId, runId);
          return;
        }
        if (st.status == ReportJobStatus.failed ||
            st.status == ReportJobStatus.expired) {
          state = state.copyWith(
              phase: ReportPhase.failed,
              error: st.error ?? 'Report generation failed. Please retry.');
          return;
        }
        if (DateTime.now().isAfter(deadline)) {
          state = state.copyWith(
              phase: ReportPhase.failed,
              error: 'Still generating after 60s. You can retry.',
              timedOut: true);
          return;
        }
      }
    } catch (e) {
      // Catch EVERYTHING (not just ApiException): otherwise a platform error
      // — e.g. path_provider/File being unavailable on web — would escape and
      // leave the UI stuck on "Generating…" forever.
      if (_runId != runId) return;
      state = state.copyWith(
          phase: ReportPhase.failed, error: _msg(e, 'Something went wrong generating the report.'));
    }
  }

  Future<void> _downloadAndFinish(String reportId, int runId) async {
    try {
      if (kIsWeb) {
        // Web has no filesystem/share sheet — stream the bytes straight to a
        // browser download instead of writing a temp File.
        final bytes = await _repo.downloadBytes(reportId);
        if (_runId != runId) return;
        triggerBrowserDownload(_asBytes(bytes), _filename(), state.format.mime);
        state = state.copyWith(
            phase: ReportPhase.ready, clearFile: true, savedToDevice: true);
        return;
      }
      final file = await _repo.download(reportId, filename: _filename());
      if (_runId != runId) return;
      state = state.copyWith(phase: ReportPhase.ready, file: file);
    } catch (e) {
      if (_runId != runId) return;
      state = state.copyWith(
          phase: ReportPhase.failed, error: _msg(e, 'Download failed. Please retry.'));
    }
  }

  static Uint8List _asBytes(List<int> data) =>
      data is Uint8List ? data : Uint8List.fromList(data);

  static String _msg(Object e, String fallback) =>
      e is ApiException ? e.message : fallback;

  Map<String, dynamic> _buildFilters() {
    if (state.isTeamReport) {
      return {
        'team_id': state.teamId,
        'month': _isoDate(state.month),
      };
    }
    final r = state.range!;
    return {
      'start_date': _isoDate(r.start),
      'end_date': _isoDate(r.end),
      if (state.teamId != null) 'team_id': state.teamId,
    };
  }

  String _filename() {
    final t = state.type.wire.toLowerCase();
    final stamp = state.isTeamReport
        ? '${state.month.year}-${_two(state.month.month)}'
        : '${_isoDate(state.range!.start)}_${_isoDate(state.range!.end)}';
    return 'fieldtrack_${t}_$stamp.${state.format.ext}';
  }

  static String _isoDate(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';
  static String _two(int n) => n.toString().padLeft(2, '0');
}

final reportProvider =
    NotifierProvider<ReportNotifier, ReportUiState>(ReportNotifier.new);
