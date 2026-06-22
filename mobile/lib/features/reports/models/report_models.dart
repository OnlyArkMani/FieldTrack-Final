import 'package:flutter/material.dart';

/// What the report covers. Mirrors the backend ReportType.
enum ReportType {
  attendance('ATTENDANCE', 'Attendance', Icons.fact_check_rounded),
  distance('DISTANCE', 'Distance', Icons.route_rounded),
  distanceZones('DISTANCE_ZONES', 'Zone Report', Icons.pin_drop_rounded),
  compliance('GEOFENCE_COMPLIANCE', 'Compliance', Icons.checklist_rounded),
  team('TEAM', 'Team overview', Icons.groups_rounded);

  const ReportType(this.wire, this.label, this.icon);
  final String wire;
  final String label;
  final IconData icon;

  /// Tabular-only report types: the backend rejects PDF for these.
  bool get supportsPdf =>
      this != ReportType.distanceZones && this != ReportType.compliance;

  /// Report types that need a team_id (server returns 400 without one). TEAM
  /// uses a month; COMPLIANCE uses a date range — both require a team.
  bool get requiresTeam =>
      this == ReportType.team || this == ReportType.compliance;

  /// Supervisor-only report types (employees don't see these chips).
  bool get supervisorOnly =>
      this == ReportType.team || this == ReportType.compliance;
}

/// Output file format. Mirrors the backend ReportFormat.
enum ReportFormat {
  pdf('PDF', 'PDF', 'pdf', Icons.picture_as_pdf_rounded),
  excel('EXCEL', 'Excel', 'xlsx', Icons.table_chart_rounded),
  csv('CSV', 'CSV', 'csv', Icons.description_rounded);

  const ReportFormat(this.wire, this.label, this.ext, this.icon);
  final String wire;
  final String label;
  final String ext;
  final IconData icon;

  String get mime => switch (this) {
        ReportFormat.pdf => 'application/pdf',
        ReportFormat.excel =>
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ReportFormat.csv => 'text/csv',
      };
}

/// Server-side job status. Mirrors the backend ReportStatus.
enum ReportJobStatus {
  processing('PROCESSING'),
  ready('READY'),
  failed('FAILED'),
  expired('EXPIRED');

  const ReportJobStatus(this.wire);
  final String wire;

  static ReportJobStatus fromWire(String? v) => ReportJobStatus.values
      .firstWhere((s) => s.wire == v, orElse: () => ReportJobStatus.processing);
}

class ReportStatusResult {
  const ReportStatusResult({
    required this.reportId,
    required this.status,
    this.downloadUrl,
    this.error,
    this.expiresAt,
  });

  final String reportId;
  final ReportJobStatus status;
  final String? downloadUrl;
  final String? error;
  final DateTime? expiresAt;

  factory ReportStatusResult.fromJson(Map<String, dynamic> json) =>
      ReportStatusResult(
        reportId: json['report_id'] as String,
        status: ReportJobStatus.fromWire(json['status'] as String?),
        downloadUrl: json['download_url'] as String?,
        error: json['error'] as String?,
        expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? '')
            ?.toLocal(),
      );
}
