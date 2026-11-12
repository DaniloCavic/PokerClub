/// Van pregledača (APK) obaveštenja preko Web Push-a nisu dostupna.
class WebPush {
  /// "unsupported", "ios-install", "default", "granted", "denied"
  static String status() => 'unsupported';

  /// Pretplata kao JSON tekst ili prazno.
  static Future<String> subscribe(String publicKey) async => '';

  /// Sto iz obaveštenja (?table=…) kad se aplikacija otvori dodirom na obaveštenje.
  static String? startTable() => null;

  static void onOpenTable(void Function(String tableId) cb) {}
}
