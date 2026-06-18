import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Typed access to .env. Features never call dotenv directly — if a key is
/// missing we fail at startup with a clear message, not mid-request.
abstract final class Env {
  static String get apiBaseUrl => _require('API_BASE_URL');
  static String get termsUrl => _require('TERMS_URL');

  // Optional — only present in production builds (see mobile/.env.prod.example).
  // Falls back so existing dev .env files without these keys keep working.
  static String? get wsBaseUrl => dotenv.maybeGet('WS_BASE_URL');
  static String get environment => dotenv.maybeGet('ENVIRONMENT') ?? 'development';

  static String _require(String key) {
    final value = dotenv.maybeGet(key);
    if (value == null || value.isEmpty) {
      throw StateError('.env is missing required key: $key');
    }
    return value;
  }
}
