import 'dart:async';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
// Prefixed: background_locator_2 also exports a `LocationAccuracy`, so the
// geolocator symbols (used only on the web path) must be disambiguated.
import 'package:geolocator/geolocator.dart' as geo;
import 'package:background_locator_2/background_locator.dart';
import 'package:background_locator_2/location_dto.dart';
import 'package:background_locator_2/settings/android_settings.dart';
import 'package:background_locator_2/settings/locator_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/attendance/models/attendance.dart';
import '../../local_db/database_helper.dart';
import 'battery_info.dart';
import 'location_sync_service.dart';

/// Background GPS. The strategy that survives Android:
///
/// - background_locator_2 runs a FOREGROUND SERVICE (persistent notification)
///   with its own Dart isolate — survives screen lock, app swipe-away, and
///   (with the OEM steps from PermissionHelperService) manufacturer killers.
/// - The plugin wakes the callback on a FIXED 3-minute cadence; the HYBRID
///   cadence is enforced in Dart by gating SAVES:
///       moving (speed > 0.5 m/s)  -> save every >= 3 min
///       stationary                -> save every >= 12 min
///       battery < 20%             -> save every >= 20 min, movement ignored
///   One service config, no service restarts to switch modes (restarting the
///   service to change intervals is exactly the kind of complexity that
///   killed the first attempt).
/// - BALANCED power accuracy (~100m, wifi/cell assisted) — HIGH would burn
///   the battery of a low-end device in half a shift.
/// - Tracking runs ONLY in STARTED/RESUMED. The background isolate re-checks
///   local_attendance_state on EVERY fix, so even if a stop message is lost,
///   no points are recorded outside working hours.
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  static const kUserIdPref = 'sync_user_id';
  static const _kLastSavedAtPref = 'loc_last_saved_at_ms';

  static const movingThresholdMps = 0.5;
  static const movingInterval = Duration(minutes: 3);
  static const stationaryInterval = Duration(minutes: 12);
  static const lowBatteryInterval = Duration(minutes: 20);

  bool _initialized = false;

  // Web only: foreground poll timer. The web target has no background isolate,
  // no SQLite queue and no foreground service, so location is produced by a
  // simple timer that reads the browser Geolocation API and posts straight to
  // /location/batch while attendance is active.
  Timer? _webPoll;

  Future<void> initialize() async {
    if (_initialized) return;
    // background_locator_2 is Android-only (getCallbackHandle is
    // unimplemented on web/desktop) — skip on non-mobile platforms so the
    // app still boots for web/dev testing.
    if (kIsWeb) {
      _initialized = true;
      return;
    }
    await BackgroundLocator.initialize();
    _initialized = true;
  }

  Future<bool> isTracking() async {
    if (kIsWeb) return _webPoll != null;
    return BackgroundLocator.isServiceRunning();
  }

  /// Single entry point — the attendance flow calls this after EVERY state
  /// change and on every rehydrate (app boot, resume). Idempotent: it
  /// converges the service to the correct on/off state for [state].
  Future<void> syncWithAttendance({
    required int userId,
    required MachineState state,
    int? attendanceId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kUserIdPref, userId);

    // WEB: no SQLite / background isolate / foreground service. The native DB
    // call below would throw here (sqflite has no web backend), so branch first
    // and drive a lightweight foreground poster instead, so a browser session
    // still shows up online, on the live map, and in the trail.
    if (kIsWeb) {
      if (state.isWorking) {
        await _startWebTracking();
      } else {
        await stop();
      }
      return;
    }

    await DatabaseHelper.instance.updateLocalAttendanceState(
      userId,
      currentState: state.wire,
      todayAttendanceId: attendanceId,
    );

    final running = await isTracking();
    if (state.isWorking && !running) {
      await _start();
    } else if (!state.isWorking && running) {
      // ON_BREAK also stops the service — no tracking during breaks; RESUME
      // brings it back. ENDED flushes whatever is still queued.
      await stop();
      if (state.isEnded) await LocationSyncService.flushPendingLocations();
    }
  }

  Future<void> _start() async {
    await initialize();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLastSavedAtPref); // first fix saves immediately

    await BackgroundLocator.registerLocationUpdate(
      locationCallbackDispatcher,
      initCallback: locationInitCallback,
      disposeCallback: locationDisposeCallback,
      autoStop: false,
      androidSettings: AndroidSettings(
        accuracy: LocationAccuracy.BALANCED, // NOT HIGH — battery
        interval: 180, // seconds; the Dart gate handles 12/20-min modes
        distanceFilter: 0,
        wakeLockTime: 60, // minutes of wakelock per cycle batch
        androidNotificationSettings: const AndroidNotificationSettings(
          notificationChannelName: 'Location tracking',
          notificationTitle: 'FieldTrack is tracking your location',
          notificationMsg: 'Active during your attendance hours',
          notificationBigMsg:
              'Location tracking is active because your attendance is '
              'running. Open the app and tap END to stop.',
          notificationIcon: '', // default app icon
          notificationIconColor: Color(0xFFF5A623), // amber dot in the shade
          // NOTE: background_locator_2 notifications don't support action
          // buttons. The required "stop" affordance is the tap action: it
          // opens the app where END stops tracking. Flagged in ANDROID_SETUP.
          notificationTapCallback: locationNotificationTapCallback,
        ),
      ),
    );
  }

  Future<void> stop() async {
    if (kIsWeb) {
      _webPoll?.cancel();
      _webPoll = null;
      return;
    }
    await BackgroundLocator.unRegisterLocationUpdate();
  }

  // ── WEB foreground location poster ─────────────────────────────────────
  // Posts the current browser position to /location/batch on a 30s cadence
  // while attendance is active (well inside the backend's 5-min "active"
  // window). No SQLite / offline queue — a browser session is online by
  // definition. The record shape mirrors the native sync path exactly, so the
  // backend, live map and trail treat web and device fixes identically.
  Future<void> _startWebTracking() async {
    if (_webPoll != null) return; // already polling
    await _postCurrentWebFix(); // immediate first fix → appears at once
    _webPoll = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _postCurrentWebFix(),
    );
  }

  Future<void> _postCurrentWebFix() async {
    try {
      var perm = await geo.Geolocator.checkPermission();
      if (perm == geo.LocationPermission.denied) {
        perm = await geo.Geolocator.requestPermission();
      }
      if (perm == geo.LocationPermission.denied ||
          perm == geo.LocationPermission.deniedForever) {
        return;
      }

      final pos = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.medium,
          timeLimit: Duration(seconds: 12),
        ),
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final baseUrl = prefs.getString(LocationSyncService.kApiBaseUrlPref);
      final token = prefs.getString(LocationSyncService.kAccessTokenPref);
      if (baseUrl == null || token == null) return;

      final dio = Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'Authorization': 'Bearer $token'},
      ));
      await dio.post('/location/batch', data: {
        'records': [
          {
            'lat': pos.latitude,
            'lng': pos.longitude,
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'accuracy': pos.accuracy,
            'speed': pos.speed,
            'battery_level': null,
            'is_mock_gps': pos.isMocked,
          }
        ],
      });
    } catch (_) {
      // Best-effort: the next tick retries. Never surface to the UI.
    }
  }

  /// Update the persistent foreground-service notification text — the line the
  /// employee sees in their notification shade. Driven from two places:
  ///   • the background location callback → "Saved locally (X points)" (offline)
  ///   • the foreground SyncEngine → "Synced X min ago" (online)
  /// Best-effort and no-ops on web / when the service isn't running.
  static Future<void> updateTrackingNotification(String msg) async {
    if (kIsWeb) return;
    try {
      await BackgroundLocator.updateNotificationText(
        title: 'FieldTrack',
        msg: msg,
        bigMsg: msg,
      );
    } catch (_) {
      // Service not running / plugin unavailable — cosmetic, safe to ignore.
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// BACKGROUND ISOLATE ENTRY POINTS — top-level + @pragma('vm:entry-point') is
// REQUIRED: the AOT tree-shaker must keep these reachable from native code.
// They run in the plugin's own isolate: NO Riverpod, NO BuildContext, no app
// singletons except what's re-creatable (sqflite, prefs, method channels).
// ═══════════════════════════════════════════════════════════════════════════

@pragma('vm:entry-point')
void locationInitCallback(Map<dynamic, dynamic> params) {
  DartPluginRegistrant.ensureInitialized();
}

@pragma('vm:entry-point')
void locationDisposeCallback() {}

@pragma('vm:entry-point')
void locationNotificationTapCallback() {
  // Brings the app to the foreground (plugin behavior); the attendance tab
  // is where the user ends tracking.
}

@pragma('vm:entry-point')
Future<void> locationCallbackDispatcher(LocationDto location) async {
  // OFFLINE-SAFE: This callback has NO network access.
  // All data goes to SQLite. Sync engine handles upload separately.
  // Reading attendance state: local DB only (local_attendance_state table).
  //
  // Recording must NEVER depend on connectivity: we save the fix to SQLite
  // first and make zero HTTP calls here. The foreground SyncEngine (and the
  // END-of-shift flush) own all uploads.
  //
  // Plugins (sqflite/prefs/battery) need registration in this isolate.
  DartPluginRegistrant.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final userId = prefs.getInt(LocationService.kUserIdPref);
  if (userId == null) return;

  // 1. GATE ON ATTENDANCE STATE — the hard rule: no tracking unless the
  //    local DB says STARTED or RESUMED. This check runs on every fix so a
  //    lost stop call can never leak off-hours points.
  final state =
      await DatabaseHelper.instance.getLocalAttendanceState(userId);
  if (state == null || !state.shouldTrack) return;

  // 2. ADAPTIVE CADENCE GATE.
  int? battery;
  try {
    battery = await BatteryInfo.instance.level();
  } catch (_) {
    battery = null; // battery read must never cost us the point
  }

  final isMoving = (location.speed) > LocationService.movingThresholdMps;
  final required = (battery != null &&
          battery < BatteryInfo.lowBatteryThreshold)
      ? LocationService.lowBatteryInterval // low battery: 20 min, period
      : isMoving
          ? LocationService.movingInterval // moving: 3 min
          : LocationService.stationaryInterval; // stationary: 12 min

  final lastSavedMs = prefs.getInt(LocationService._kLastSavedAtPref);
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  if (lastSavedMs != null && nowMs - lastSavedMs < required.inMilliseconds) {
    return; // not due yet
  }

  // 3. SAVE LOCALLY FIRST — SQLite is the durability boundary, network is
  //    best-effort. is_mock_gps comes straight from the OS fix (flag only,
  //    no block — per product decision; admin sees it).
  await DatabaseHelper.instance.insertLocationLog(PendingLocation(
    userId: userId,
    lat: location.latitude,
    lng: location.longitude,
    timestamp:
        DateTime.fromMillisecondsSinceEpoch(location.time.toInt(), isUtc: false)
            .toUtc(),
    accuracy: location.accuracy,
    speed: location.speed,
    batteryLevel: battery,
    isMockGps: location.isMocked,
  ));
  await prefs.setInt(LocationService._kLastSavedAtPref, nowMs);

  // 4. UPDATE THE FOREGROUND-SERVICE NOTIFICATION (no network) so the shade
  //    reflects that points are being buffered locally. Best-effort: a failed
  //    notification update must never cost us the saved point.
  try {
    final pending =
        await DatabaseHelper.instance.getPendingLocationCount();
    await LocationService.updateTrackingNotification(
      'FieldTrack · Tracking active · Saved locally ($pending points)',
    );
  } catch (_) {
    // ignore — notification text is cosmetic; the SQLite write above is what
    // matters and has already succeeded.
  }
  // NO HTTP HERE. Upload is exclusively the SyncEngine's job (offline-safe).
}
