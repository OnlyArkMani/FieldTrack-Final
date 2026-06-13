import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/state_views.dart';
import '../../../services/map/map_service.dart';
import '../../employees/widgets/employee_avatar.dart';
import '../models/trail.dart';
import '../providers/map_provider.dart';
import '../widgets/employee_marker.dart';

/// Replays an employee's movement for a day: full route + animated playback
/// along the track, with attendance session markers and mock-GPS warnings.
class TrailReplayScreen extends ConsumerStatefulWidget {
  const TrailReplayScreen({
    super.key,
    required this.employeeId,
    required this.employeeName,
    this.photoUrl,
  });

  final int employeeId;
  final String employeeName;
  final String? photoUrl;

  @override
  ConsumerState<TrailReplayScreen> createState() => _TrailReplayScreenState();
}

class _TrailReplayScreenState extends ConsumerState<TrailReplayScreen> {
  final _mapController = MapController();
  DateTime _date = DateTime.now();
  int _idx = 0;
  bool _playing = false;
  int _speed = 1; // 1x / 2x / 5x
  Timer? _timer;

  static const _tickMs = {1: 100, 2: 50, 5: 20};

  String get _ymd => DateFormat('yyyy-MM-dd').format(_date);
  TrailArgs get _args => (userId: widget.employeeId, date: _ymd);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _resetPlayback() {
    _timer?.cancel();
    setState(() {
      _idx = 0;
      _playing = false;
    });
  }

  void _togglePlay(int total) {
    if (total == 0) return;
    if (_playing) {
      _timer?.cancel();
      setState(() => _playing = false);
      return;
    }
    if (_idx >= total - 1) _idx = 0; // replay from start
    setState(() => _playing = true);
    _startTimer(total);
  }

  void _startTimer(int total) {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: _tickMs[_speed]!), (_) {
      if (_idx >= total - 1) {
        _timer?.cancel();
        setState(() => _playing = false);
        return;
      }
      setState(() => _idx++);
      _followCamera();
    });
  }

  void _setSpeed(int s, int total) {
    setState(() => _speed = s);
    if (_playing) _startTimer(total); // restart at the new cadence
  }

  void _followCamera() {
    final pts = ref.read(trailProvider(_args)).valueOrNull?.points;
    if (pts == null || _idx >= pts.length) return;
    _mapController.move(pts[_idx].position, _mapController.camera.zoom);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2023),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      _timer?.cancel();
      setState(() {
        _date = picked;
        _idx = 0;
        _playing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(trailProvider(_args));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trail', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorStateView(
          message: e.toString(),
          onRetry: () => ref.invalidate(trailProvider(_args)),
        ),
        data: (trail) => _buildBody(trail),
      ),
    );
  }

  Widget _buildBody(TrailRoute trail) {
    final points = trail.points;
    final hasData = points.isNotEmpty;
    final clampedIdx = hasData ? _idx.clamp(0, points.length - 1) : 0;
    final current = hasData ? points[clampedIdx] : null;
    final full = [for (final p in points) p.position];
    final played = hasData ? full.sublist(0, clampedIdx + 1) : <LatLng>[];
    final center = current?.position ?? const LatLng(20.5937, 78.9629);

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: hasData ? 16 : 5,
            minZoom: 3,
            maxZoom: 18,
          ),
          children: [
            MapService.tileLayer(),
            if (full.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(points: full, strokeWidth: 3, color: AppPalette.statusOffline),
                ],
              ),
            if (played.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(points: played, strokeWidth: 4, color: AppPalette.amber),
                ],
              ),
            // mock-GPS warning dots
            CircleLayer(
              circles: [
                for (final p in points)
                  if (p.isMockGps)
                    CircleMarker(
                      point: p.position,
                      radius: 5,
                      color: AppPalette.coral,
                      borderColor: Colors.white,
                      borderStrokeWidth: 1,
                    ),
              ],
            ),
            // session markers
            MarkerLayer(
              markers: [
                for (final s in trail.sessions)
                  if (s.position != null)
                    Marker(
                      point: s.position!,
                      width: 30,
                      height: 30,
                      child: _SessionPin(type: s.type),
                    ),
              ],
            ),
            // current position (pulsing amber dot)
            if (current != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: current.position,
                    width: 28,
                    height: 28,
                    child: const _PulsingDot(),
                  ),
                ],
              ),
          ],
        ),
        _BottomSheet(
          employeeName: widget.employeeName,
          photoUrl: widget.photoUrl,
          date: _date,
          trail: trail,
          current: current,
          idx: clampedIdx,
          playing: _playing,
          speed: _speed,
          onPickDate: _pickDate,
          onRestart: _resetPlayback,
          onTogglePlay: () => _togglePlay(points.length),
          onSpeed: (s) => _setSpeed(s, points.length),
          onScrub: (v) {
            _timer?.cancel();
            setState(() {
              _playing = false;
              _idx = v;
            });
            _followCamera();
          },
        ),
      ],
    );
  }
}

class _BottomSheet extends StatelessWidget {
  const _BottomSheet({
    required this.employeeName,
    required this.photoUrl,
    required this.date,
    required this.trail,
    required this.current,
    required this.idx,
    required this.playing,
    required this.speed,
    required this.onPickDate,
    required this.onRestart,
    required this.onTogglePlay,
    required this.onSpeed,
    required this.onScrub,
  });

  final String employeeName;
  final String? photoUrl;
  final DateTime date;
  final TrailRoute trail;
  final TrailPoint? current;
  final int idx;
  final bool playing;
  final int speed;
  final VoidCallback onPickDate;
  final VoidCallback onRestart;
  final VoidCallback onTogglePlay;
  final ValueChanged<int> onSpeed;
  final ValueChanged<int> onScrub;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final pointCount = trail.points.length;

    return DraggableScrollableSheet(
      initialChildSize: 0.4,
      minChildSize: 0.4,
      maxChildSize: 0.7,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppDimens.sheetRadius),
          ),
          boxShadow: AppDimens.shadow(Theme.of(context).brightness),
        ),
        child: ListView(
          controller: scrollController,
          padding: const EdgeInsets.all(AppDimens.grid * 2),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AppDimens.grid * 1.5),
            // Header: avatar + name + date picker
            Row(
              children: [
                EmployeeAvatar(initials: _initials(employeeName), photoUrl: photoUrl, radius: 20),
                const SizedBox(width: AppDimens.grid * 1.5),
                Expanded(
                  child: Text(
                    employeeName,
                    style: AppTextStyles.heading.copyWith(color: scheme.onSurface, fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton.icon(
                  onPressed: onPickDate,
                  icon: const Icon(Icons.calendar_today_rounded, size: 16),
                  label: Text(DateFormat('d MMM').format(date)),
                ),
              ],
            ),

            if (pointCount == 0) ...[
              const SizedBox(height: AppDimens.grid * 2),
              const EmptyStateView(
                icon: Icons.event_busy_rounded,
                title: 'No location data for this date',
                message: 'Pick another day to replay a recorded trail.',
              ),
            ] else ...[
              const SizedBox(height: AppDimens.grid * 1.5),
              // Stats
              Row(
                children: [
                  _Stat(label: 'Distance', value: '${(trail.totalDistanceMeters / 1000).toStringAsFixed(2)} km'),
                  _Stat(label: 'Active time', value: _fmtDur(trail.totalDurationMinutes)),
                  _Stat(label: 'Points', value: '$pointCount'),
                ],
              ),
              const SizedBox(height: AppDimens.grid * 1.5),
              // Playback controls
              Row(
                children: [
                  IconButton(
                    onPressed: onRestart,
                    icon: const Icon(Icons.replay_rounded),
                    tooltip: 'Restart',
                  ),
                  IconButton.filled(
                    onPressed: onTogglePlay,
                    icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                    tooltip: playing ? 'Pause' : 'Play',
                  ),
                  const SizedBox(width: AppDimens.grid),
                  for (final s in [1, 2, 5])
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: Text('${s}x'),
                        selected: speed == s,
                        onSelected: (_) => onSpeed(s),
                      ),
                    ),
                ],
              ),
              // Scrubber
              Slider(
                value: pointCount <= 1 ? 0 : idx / (pointCount - 1),
                onChanged: (v) => onScrub((v * (pointCount - 1)).round()),
              ),
              // Current point info
              if (current != null)
                Row(
                  children: [
                    Icon(Icons.schedule_rounded, size: 16, color: colors.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      DateFormat('HH:mm:ss').format(current!.timestamp.toLocal()),
                      style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
                    ),
                    const SizedBox(width: AppDimens.grid),
                    Text(
                      current!.speed != null ? '${(current!.speed! * 3.6).toStringAsFixed(1)} km/h' : '— km/h',
                      style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
                    ),
                    const Spacer(),
                    if (current!.attendanceState != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: AppDimens.grid, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppPalette.amber.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          current!.attendanceState!,
                          style: AppTextStyles.caption.copyWith(
                            color: AppPalette.amber,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (current!.isMockGps) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error),
                    ],
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }

  static String _fmtDur(int min) {
    if (min <= 0) return '0m';
    final h = min ~/ 60;
    final m = min % 60;
    return h == 0 ? '${m}m' : '${h}h ${m}m';
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: AppTextStyles.bodyMedium
                  .copyWith(color: Theme.of(context).colorScheme.onSurface)),
          Text(label, style: AppTextStyles.caption.copyWith(color: colors.textSecondary)),
        ],
      ),
    );
  }
}

class _SessionPin extends StatelessWidget {
  const _SessionPin({required this.type});
  final String type;

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon) = switch (type) {
      'START' => (AppPalette.statusActive, Icons.play_arrow_rounded),
      'BREAK' => (AppPalette.amber, Icons.pause_rounded),
      'RESUME' => (const Color(0xFF3B82F6), Icons.play_arrow_rounded),
      'END' => (AppPalette.coral, Icons.stop_rounded),
      _ => (AppPalette.statusOffline, Icons.circle),
    };
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 3),
        ],
      ),
      child: Icon(icon, size: 16, color: Colors.white),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeOut.transform(_c.value);
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 16 + 12 * t,
              height: 16 + 12 * t,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppPalette.amber.withValues(alpha: (1 - t) * 0.4),
              ),
            ),
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppPalette.amber,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ],
        );
      },
    );
  }
}
