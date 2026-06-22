import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/shimmer_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../services/map/map_service.dart';
import '../../../services/map/tile_cache_service.dart';
import '../../auth/models/user.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/geofence.dart';
import '../models/map_models.dart';
import '../providers/map_provider.dart';
import '../widgets/employee_marker.dart';
import '../widgets/geofence_layer.dart';

/// Tab 3. Role-aware: employees see their own route + distance; supervisors see
/// their team's live positions. flutter_map + OpenStreetMap, offline-cached.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _controller = MapController();

  @override
  void initState() {
    super.initState();
    // Warm the tile cache up (best-effort; map renders regardless).
    TileCacheService.instance.initializeCache();
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(authProvider).user?.role;
    final isSupervisor = role == UserRole.supervisor;

    return Scaffold(
      appBar: AppBar(
        title: Text(isSupervisor ? 'Team Map' : 'My Route',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (!isSupervisor) const _ModeToggle(),
          const SizedBox(width: AppDimens.grid),
        ],
      ),
      body: SafeArea(
        child: isSupervisor
            ? _SupervisorMap(controller: _controller)
            : _EmployeeMap(controller: _controller),
      ),
    );
  }
}

class _ModeToggle extends ConsumerWidget {
  const _ModeToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(mapViewModeProvider);
    final isWeek = mode == MapViewMode.week;
    return Center(
      child: GestureDetector(
        onTap: () => ref.read(mapViewModeProvider.notifier).state =
            isWeek ? MapViewMode.today : MapViewMode.week,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.grid * 1.5, vertical: AppDimens.grid * 0.5),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(isWeek ? Icons.blur_on_rounded : Icons.timeline_rounded,
                  size: 15, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 4),
              Text(
                isWeek ? '7-day' : 'Today',
                style: AppTextStyles.caption.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Employee view ──────────────────────────────────────────────────────────
class _EmployeeMap extends ConsumerWidget {
  const _EmployeeMap({required this.controller});
  final MapController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(mapViewModeProvider);
    if (mode == MapViewMode.week) {
      return _WeekHeatmap(controller: controller);
    }
    return _TodayRoute(controller: controller);
  }
}

class _TodayRoute extends ConsumerWidget {
  const _TodayRoute({required this.controller});
  final MapController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routeAsync = ref.watch(todayRouteProvider);
    final device = ref.watch(deviceLocationProvider).valueOrNull;
    final geofences = ref.watch(geofencesProvider).valueOrNull ?? const <Geofence>[];
    final showZones = ref.watch(showZonesProvider);

    return routeAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppDimens.grid * 2),
        child: MapShimmer(),
      ),
      error: (e, _) => ErrorStateView(
        message: e.toString(),
        onRetry: () => ref.invalidate(todayRouteProvider),
      ),
      data: (route) {
        final raw = route?.points ?? const <LatLng>[];
        final points = MapService.smoothRoute(raw);
        final hasRoute = points.length >= 2;
        final start = points.isNotEmpty ? points.first : null;
        final current = points.isNotEmpty ? points.last : null;
        final center = device ?? current ?? start ?? const LatLng(20.5937, 78.9629);
        final distance = MapService.totalDistanceMeters(points);

        return Stack(
          children: [
            FlutterMap(
              mapController: controller,
              options: MapOptions(
                initialCenter: center,
                initialZoom: hasRoute ? 15 : 5,
                minZoom: 3,
                maxZoom: 18,
                onTap: (_, latlng) {
                  if (!showZones) return;
                  final g = _hitGeofence(geofences, latlng);
                  if (g != null) _showEmployeeZoneSheet(context, ref, g);
                },
              ),
              children: [
                MapService.tileLayer(),
                if (showZones && geofences.isNotEmpty)
                  ...geofenceLayers(geofences),
                if (hasRoute)
                  _AnimatedRouteLayer(
                    points: points,
                    color: AppPalette.amber,
                    strokeWidth: 3,
                  ),
                MarkerLayer(
                  markers: [
                    if (start != null)
                      Marker(
                        point: start,
                        width: 28,
                        height: 28,
                        child: const _Dot(color: AppPalette.statusActive, icon: Icons.flag_rounded),
                      ),
                    if (current != null)
                      Marker(
                        point: current,
                        width: 30,
                        height: 30,
                        child: const _Dot(color: AppPalette.amber, icon: Icons.navigation_rounded),
                      ),
                    if (device != null)
                      Marker(
                        point: device,
                        width: 26,
                        height: 26,
                        child: const _PulsingBlueDot(),
                      ),
                  ],
                ),
              ],
            ),
            if (geofences.isNotEmpty)
              Positioned(
                top: AppDimens.grid * 2,
                right: AppDimens.grid * 2,
                child: _ZoneToggle(
                  visible: showZones,
                  onTap: () => ref.read(showZonesProvider.notifier).state =
                      !showZones,
                ),
              ),
            Positioned(
              left: AppDimens.grid * 2,
              right: AppDimens.grid * 2,
              bottom: AppDimens.grid * 2,
              child: _DistanceCard(
                distanceMeters: distance,
                pointCount: route?.rawCount ?? 0,
                empty: !hasRoute,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _WeekHeatmap extends ConsumerWidget {
  const _WeekHeatmap({required this.controller});
  final MapController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final weekAsync = ref.watch(weekRouteProvider);
    return weekAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppDimens.grid * 2),
        child: MapShimmer(),
      ),
      error: (e, _) => ErrorStateView(
        message: e.toString(),
        onRetry: () => ref.invalidate(weekRouteProvider),
      ),
      data: (points) {
        if (points.isEmpty) {
          return const EmptyStateView(
            icon: Icons.blur_on_rounded,
            title: 'No movement in the last 7 days',
            message: 'Your route heatmap will appear as you work.',
          );
        }
        final center = points.first;
        return FlutterMap(
          mapController: controller,
          options: MapOptions(initialCenter: center, initialZoom: 13, minZoom: 3, maxZoom: 18),
          children: [
            MapService.tileLayer(),
            CircleLayer(
              circles: [
                for (final p in points)
                  CircleMarker(
                    point: p,
                    radius: 7,
                    useRadiusInMeter: false,
                    color: AppPalette.coral.withValues(alpha: 0.18),
                    borderStrokeWidth: 0,
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

// ── Supervisor view ──────────────────────────────────────────────────────────
class _SupervisorMap extends ConsumerWidget {
  const _SupervisorMap({required this.controller});
  final MapController controller;

  // Centre of India — the map always opens here when there are no located
  // members, so supervisors see tiles (not a blank screen) from the first frame.
  static const _indiaCenter = LatLng(20.5937, 78.9629);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teamAsync = ref.watch(teamLiveProvider);
    final geofences = ref.watch(geofencesProvider).valueOrNull ?? const <Geofence>[];
    final showZones = ref.watch(showZonesProvider);

    // The map renders in EVERY state — loading, error and empty just change the
    // overlay drawn on top of it. (Previously these returned a non-map widget,
    // so the supervisor saw a blank/empty screen with no tiles at all.)
    final members = teamAsync.valueOrNull ?? const <TeamLiveMember>[];
    final located = members.where((m) => m.hasPosition).toList();
    final error = teamAsync.hasError ? teamAsync.error : null;

    return _buildMap(
      context,
      ref,
      located: located,
      geofences: geofences,
      showZones: showZones,
      teamSize: members.length,
      isLoading: teamAsync.isLoading,
      error: error,
    );
  }

  Widget _buildMap(
    BuildContext context,
    WidgetRef ref, {
    required List<TeamLiveMember> located,
    required List<Geofence> geofences,
    required bool showZones,
    required int teamSize,
    required bool isLoading,
    required Object? error,
  }) {
    // Fly to the first active member if we have one; otherwise show all of India.
    final hasMembers = located.isNotEmpty;
    final center = hasMembers ? located.first.position! : _indiaCenter;

    return Stack(
      children: [
        FlutterMap(
          mapController: controller,
          options: MapOptions(
            initialCenter: center,
            initialZoom: hasMembers ? 13 : 5,
            minZoom: 3,
            maxZoom: 18,
            onTap: (_, latlng) {
              if (!showZones) return;
              final g = _hitGeofence(geofences, latlng);
              if (g != null) _showSupervisorZoneSheet(context, g, teamSize);
            },
          ),
          children: [
            // TileLayer must be the first child or nothing renders.
            MapService.tileLayer(),
            if (showZones && geofences.isNotEmpty)
              ...geofenceLayers(geofences),
            MarkerLayer(
              markers: [
                for (final m in located)
                  Marker(
                    point: m.position!,
                    width: 40,
                    height: 40,
                    child: EmployeeMarker(
                      member: m,
                      onTap: () => _showMemberSheet(context, m),
                    ),
                  ),
              ],
            ),
          ],
        ),

        // Show/Hide Zones toggle (top-right), only when there are zones.
        if (geofences.isNotEmpty)
          Positioned(
            top: AppDimens.grid * 2,
            right: AppDimens.grid * 2,
            child: _ZoneToggle(
              visible: showZones,
              onTap: () =>
                  ref.read(showZonesProvider.notifier).state = !showZones,
            ),
          ),

        // ── Overlays (drawn OVER the map, never instead of it) ──────────────
        if (error != null && located.isEmpty)
          _MapOverlay(
            icon: Icons.wifi_off_rounded,
            title: "Couldn't load team locations",
            message: 'Pull to retry — showing the last known view.',
            onRetry: () => ref.invalidate(teamLiveProvider),
          )
        else if (located.isEmpty)
          _MapOverlay(
            icon: isLoading ? Icons.my_location_rounded : Icons.location_off_rounded,
            title: isLoading ? 'Locating your team…' : 'No team members are currently active',
            message: isLoading
                ? null
                : 'They appear on the map as soon as they start sharing location.',
          ),
      ],
    );
  }

  void _showMemberSheet(BuildContext context, TeamLiveMember m) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _MemberSheet(member: m),
    );
  }
}

class _MemberSheet extends StatelessWidget {
  const _MemberSheet({required this.member});
  final TeamLiveMember member;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppDimens.sheetRadius),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppDimens.grid * 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  EmployeeMarker(member: member, diameter: 48),
                  const SizedBox(width: AppDimens.grid * 1.5),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(member.name,
                            style: AppTextStyles.heading
                                .copyWith(color: scheme.onSurface),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        StatusBadgeFor(status: member.status),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppDimens.grid * 2),
              _SheetRow(
                icon: Icons.fingerprint_rounded,
                label: 'Attendance',
                value: _stateLabel(member.attendanceState),
              ),
              _SheetRow(
                icon: Icons.schedule_rounded,
                label: 'Last seen',
                value: member.lastSeen != null
                    ? _relative(member.lastSeen!)
                    : 'Unknown',
              ),
              if (member.batteryLevel != null)
                _SheetRow(
                  icon: Icons.battery_full_rounded,
                  label: 'Battery',
                  value: '${member.batteryLevel}%',
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _stateLabel(String wire) => switch (wire) {
        'STARTED' || 'RESUMED' => 'Working',
        'ON_BREAK' => 'On break',
        'ENDED' => 'Shift ended',
        _ => 'Not started',
      };
}

// ── Small shared bits ────────────────────────────────────────────────────────
class StatusBadgeFor extends StatelessWidget {
  const StatusBadgeFor({super.key, required this.status});
  final LiveStatusValue status;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final (Color c, String label) = switch (status) {
      LiveStatusValue.active => (colors.statusActive, 'Active'),
      LiveStatusValue.idle => (colors.statusIdle, 'Idle'),
      LiveStatusValue.offline => (colors.statusOffline, 'Offline'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.grid, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: AppTextStyles.caption
              .copyWith(color: c, fontWeight: FontWeight.w500)),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.grid * 0.75),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.textSecondary),
          const SizedBox(width: AppDimens.grid * 1.5),
          Text(label,
              style: AppTextStyles.body.copyWith(color: colors.textSecondary)),
          const Spacer(),
          Flexible(
            child: Text(value,
                style: AppTextStyles.bodyMedium
                    .copyWith(color: Theme.of(context).colorScheme.onSurface),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class _DistanceCard extends StatelessWidget {
  const _DistanceCard({
    required this.distanceMeters,
    required this.pointCount,
    required this.empty,
  });
  final double distanceMeters;
  final int pointCount;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final km = distanceMeters / 1000;
    return AppCard(
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
            ),
            child: Icon(Icons.directions_walk_rounded,
                size: 22, color: scheme.primary),
          ),
          const SizedBox(width: AppDimens.grid * 1.5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  empty
                      ? 'No route yet today'
                      : km >= 1
                          ? '${km.toStringAsFixed(2)} km today'
                          : '${distanceMeters.round()} m today',
                  style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  empty ? 'Start attendance to begin tracking' : '$pointCount points recorded',
                  style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.icon});
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Icon(icon, size: 16, color: Colors.white),
    );
  }
}

class _PulsingBlueDot extends StatefulWidget {
  const _PulsingBlueDot();

  @override
  State<_PulsingBlueDot> createState() => _PulsingBlueDotState();
}

class _PulsingBlueDotState extends State<_PulsingBlueDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  static const _blue = Color(0xFF3B82F6);

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
              width: 12 + 14 * t,
              height: 12 + 14 * t,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _blue.withValues(alpha: (1 - t) * 0.4),
              ),
            ),
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _blue,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Polyline that "draws" from start to current over 1.5s on load, by tweening
/// the number of points rendered.
class _AnimatedRouteLayer extends StatefulWidget {
  const _AnimatedRouteLayer({
    required this.points,
    required this.color,
    required this.strokeWidth,
  });

  final List<LatLng> points;
  final Color color;
  final double strokeWidth;

  @override
  State<_AnimatedRouteLayer> createState() => _AnimatedRouteLayerState();
}

class _AnimatedRouteLayerState extends State<_AnimatedRouteLayer> {
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(widget.points.length),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1500),
      curve: Curves.easeInOutCubic,
      builder: (context, t, _) {
        final count = (widget.points.length * t).clamp(2, widget.points.length).toInt();
        final drawn = widget.points.sublist(0, count);
        return PolylineLayer(
          polylines: [
            Polyline(
              points: drawn,
              strokeWidth: widget.strokeWidth,
              color: widget.color,
            ),
          ],
        );
      },
    );
  }
}

String _relative(DateTime dt) {
  final diff = DateTime.now().difference(dt.toLocal());
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

// ── Geofence zone interaction (Change 2) ─────────────────────────────────────

/// First zone whose boundary contains [p] (field zones don't overlap in
/// practice). Returns null when the tap missed every zone.
Geofence? _hitGeofence(List<Geofence> zones, LatLng p) {
  for (final g in zones) {
    if (g.contains(p)) return g;
  }
  return null;
}

String _zoneDuration(double minutes) {
  final m = minutes.round();
  final h = m ~/ 60;
  final rem = m % 60;
  if (h > 0) return '$h hour${h == 1 ? '' : 's'} $rem minute${rem == 1 ? '' : 's'}';
  return '$rem minute${rem == 1 ? '' : 's'}';
}

String _zoneRadius(double m) =>
    m >= 1000 ? '${(m / 1000).toStringAsFixed(m % 1000 == 0 ? 0 : 1)} km' : '${m.round()} m';

String _zoneArea(double? sqm) {
  if (sqm == null || sqm <= 0) return '—';
  if (sqm >= 1000000) return '${(sqm / 1000000).toStringAsFixed(2)} km²';
  return '${sqm.round()} m²';
}

void _showEmployeeZoneSheet(BuildContext context, WidgetRef ref, Geofence g) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _EmployeeZoneSheet(geofence: g),
  );
}

void _showSupervisorZoneSheet(BuildContext context, Geofence g, int teamSize) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _SupervisorZoneSheet(geofence: g, teamSize: teamSize),
  );
}

/// Floating "Show/Hide Zones" pill (top-right of the map). Eye icon swaps with
/// an AnimatedSwitcher.
class _ZoneToggle extends StatelessWidget {
  const _ZoneToggle({required this.visible, required this.onTap});
  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: colors.card.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(999),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.grid * 1.25, vertical: AppDimens.grid * 0.75),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: ScaleTransition(scale: anim, child: child)),
                child: Icon(
                  visible ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                  key: ValueKey(visible),
                  size: 16,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                visible ? 'Hide Zones' : 'Show Zones',
                style: AppTextStyles.caption
                    .copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared rounded sheet container (mirrors _MemberSheet styling).
class _ZoneSheetShell extends StatelessWidget {
  const _ZoneSheetShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppDimens.sheetRadius),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppDimens.grid * 3),
          child: child,
        ),
      ),
    );
  }
}

class _ZoneSheetHeader extends StatelessWidget {
  const _ZoneSheetHeader({required this.name, required this.scope});
  final String name;
  final String scope;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final isTeam = scope == 'TEAM';
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.primary.withValues(alpha: 0.14),
          ),
          child: Icon(Icons.place_rounded, color: scheme.primary),
        ),
        const SizedBox(width: AppDimens.grid * 1.5),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style: AppTextStyles.heading.copyWith(color: scheme.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(isTeam ? Icons.groups_rounded : Icons.public_rounded,
                      size: 13, color: colors.textSecondary),
                  const SizedBox(width: 4),
                  Text(isTeam ? 'Team zone' : 'Universal',
                      style: AppTextStyles.caption
                          .copyWith(color: colors.textSecondary)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmployeeZoneSheet extends ConsumerWidget {
  const _EmployeeZoneSheet({required this.geofence});
  final Geofence geofence;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final visitsAsync = ref.watch(employeeZonesTodayProvider);
    final g = geofence;
    final shapeLine = g.isCircle
        ? 'Circle · ${_zoneRadius(g.radiusMeters!)} radius'
        : 'Polygon · ${_zoneArea(g.areaSqMeters)}';

    return _ZoneSheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ZoneSheetHeader(name: g.name, scope: g.scope),
          const SizedBox(height: AppDimens.grid * 2),
          _SheetRow(
            icon: Icons.category_rounded,
            label: 'Shape',
            value: shapeLine,
          ),
          visitsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: AppDimens.grid * 1.5),
              child: LinearProgressIndicator(minHeight: 2),
            ),
            error: (_, __) => _SheetRow(
              icon: Icons.timelapse_rounded,
              label: 'Today',
              value: 'Unavailable',
            ),
            data: (map) {
              final v = map[g.id];
              final value = (v != null && v.totalMinutes > 0)
                  ? _zoneDuration(v.totalMinutes)
                  : 'Not visited yet';
              return _SheetRow(
                icon: Icons.timelapse_rounded,
                label: 'You visited today',
                value: value,
              );
            },
          ),
          const SizedBox(height: AppDimens.grid),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Tap a zone for details',
              style: AppTextStyles.caption
                  .copyWith(color: scheme.onSurface.withValues(alpha: 0.4)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SupervisorZoneSheet extends ConsumerWidget {
  const _SupervisorZoneSheet({required this.geofence, required this.teamSize});
  final Geofence geofence;
  final int teamSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final presenceAsync = ref.watch(zonePresenceProvider(geofence.id));

    return _ZoneSheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ZoneSheetHeader(name: geofence.name, scope: geofence.scope),
          const SizedBox(height: AppDimens.grid * 2),
          presenceAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: AppDimens.grid * 2),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
            ),
            error: (_, __) => Text(
              "Couldn't load today's visits.",
              style: AppTextStyles.body.copyWith(color: scheme.onSurface),
            ),
            data: (list) {
              // Aggregate dwell per member; null duration => still inside.
              final byUser = <int, ({String name, double minutes, bool inside})>{};
              for (final p in list) {
                final cur = byUser[p.userId];
                final add = p.durationMinutes ?? 0;
                byUser[p.userId] = (
                  name: p.employeeName ?? 'Employee ${p.userId}',
                  minutes: (cur?.minutes ?? 0) + add,
                  inside: (cur?.inside ?? false) || p.durationMinutes == null,
                );
              }
              final visited = byUser.length;
              final entries = byUser.values.toList()
                ..sort((a, b) => b.minutes.compareTo(a.minutes));

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppDimens.grid * 1.5,
                        vertical: AppDimens.grid),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.groups_rounded, size: 18, color: scheme.primary),
                        const SizedBox(width: AppDimens.grid),
                        Expanded(
                          child: Text(
                            '$visited of $teamSize team member${teamSize == 1 ? '' : 's'} visited today',
                            style: AppTextStyles.bodyMedium
                                .copyWith(color: scheme.onSurface),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppDimens.grid * 1.5),
                  if (entries.isEmpty)
                    Text('No team members entered this zone today.',
                        style: AppTextStyles.body
                            .copyWith(color: colors.textSecondary))
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: entries.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: AppDimens.grid * 0.5),
                        itemBuilder: (_, i) {
                          final e = entries[i];
                          final dwell = e.inside
                              ? 'Inside now'
                              : _zoneDuration(e.minutes);
                          return _SheetRow(
                            icon: Icons.person_rounded,
                            label: e.name,
                            value: dwell,
                          );
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// A compact, centred card drawn ON TOP of the live map (the map keeps its
/// tiles visible behind it). Used for the supervisor map's empty / loading /
/// error states so the screen is never blank.
class _MapOverlay extends StatelessWidget {
  const _MapOverlay({
    required this.icon,
    required this.title,
    this.message,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      ignoring: onRetry == null,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.all(AppDimens.grid * 2),
          child: AppCard(
            color: colors.card.withValues(alpha: 0.94),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: scheme.primary, size: 28),
                const SizedBox(height: AppDimens.grid),
                Text(
                  title,
                  style: AppTextStyles.bodyMedium.copyWith(color: scheme.onSurface),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (message != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    message!,
                    style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (onRetry != null) ...[
                  const SizedBox(height: AppDimens.grid * 1.5),
                  AppButton(
                    label: 'Retry',
                    variant: AppButtonVariant.secondary,
                    icon: Icons.refresh_rounded,
                    expanded: false,
                    onPressed: onRetry,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
