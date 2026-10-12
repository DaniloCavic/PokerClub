import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb, kReleaseMode;

/// Adresa servera. Za produkciju se zadaje pri izgradnji:
///   flutter build apk --dart-define=API_URL=https://moj-server.up.railway.app
/// U razvoju: Android emulator vidi računar kao 10.0.2.2, iOS simulator kao localhost.
/// Za pravi telefon u istoj mreži: --dart-define=API_URL=http://192.168.x.x:3000
const _fromEnv = String.fromEnvironment('API_URL');

String get apiBaseUrl {
  if (_fromEnv.isNotEmpty) return _fromEnv;
  // Web verzija se servira sa istog servera, pa koristi istu adresu.
  if (kIsWeb && kReleaseMode) return Uri.base.origin;
  if (kIsWeb) return 'http://localhost:3000';
  return defaultTargetPlatform == TargetPlatform.android ? 'http://10.0.2.2:3000' : 'http://localhost:3000';
}
