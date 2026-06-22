import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/geofence.dart';
import '../models/map_models.dart';
import '../models/trail.dart';

final mapRepositoryProvider = Provider<MapRepository>((ref) {
  return MapRepository(ref.watch(apiClientProvider));
});

class MapRepository {
  MapRepository(this._api);
  final ApiClient _api;

  /// A user's route for [date] (defaults to today server-side if omitted).
  Future<RouteData> route(int userId, {DateTime? date}) async {
    final query = <String, dynamic>{};
    if (date != null) query['date'] = _ymd(date);
    final data = await _api.get('/location/route/$userId', query: query);
    return RouteData.fromJson(data);
  }

  /// Enriched trail-replay route for [userId] on [date] (defaults to today).
  Future<TrailRoute> trail(int userId, {DateTime? date}) async {
    final query = <String, dynamic>{};
    if (date != null) query['date'] = _ymd(date);
    final data = await _api.get('/location/route/$userId', query: query);
    return TrailRoute.fromJson(data);
  }

  /// Live positions of the supervisor's team members.
  Future<List<TeamLiveMember>> teamLive() async {
    final data = await _api.getList('/location/team-live');
    return data
        .map((e) => TeamLiveMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Active geofences to render on the map (already role/team-scoped server-side).
  Future<List<Geofence>> geofences() async {
    final data = await _api.getList('/geofences');
    return data
        .map((e) => Geofence.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Zones the employee visited today (geofence_id → visits + minutes).
  Future<List<ZoneVisit>> employeeZonesToday(int userId, {DateTime? date}) async {
    final query = <String, dynamic>{};
    if (date != null) query['date'] = _ymd(date);
    final data = await _api.getList('/geofences/employee/$userId/today', query: query);
    return data
        .map((e) => ZoneVisit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Who from the team was inside [geofenceId] today (ENTER/EXIT pairs + dwell).
  Future<List<ZonePresence>> zonePresence(int geofenceId, {DateTime? date}) async {
    final query = <String, dynamic>{};
    if (date != null) query['date'] = _ymd(date);
    final data = await _api.getList('/geofences/$geofenceId/presence', query: query);
    return data
        .map((e) => ZonePresence.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
