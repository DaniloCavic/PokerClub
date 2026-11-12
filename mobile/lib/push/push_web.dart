import 'dart:js_interop';

@JS('trilingPush.status')
external JSString _status();

@JS('trilingPush.subscribe')
external JSPromise<JSString> _subscribe(JSString key);

@JS('trilingPush.onOpenTable')
external void _onOpenTable(JSFunction cb);

/// Obaveštenja u pregledaču (Web Push), preko web/push.js.
class WebPush {
  /// "unsupported", "ios-install", "default", "granted", "denied"
  static String status() {
    try {
      return _status().toDart;
    } catch (_) {
      return 'unsupported';
    }
  }

  /// Traži dozvolu i pretplaćuje uređaj; vraća pretplatu kao JSON tekst ili prazno.
  static Future<String> subscribe(String publicKey) async {
    try {
      return (await _subscribe(publicKey.toJS).toDart).toDart;
    } catch (_) {
      return '';
    }
  }

  /// Sto iz obaveštenja (?table=…) kad se aplikacija otvori dodirom na obaveštenje.
  static String? startTable() => Uri.base.queryParameters['table'];

  /// Dodir na obaveštenje dok je aplikacija već otvorena.
  static void onOpenTable(void Function(String tableId) cb) {
    try {
      _onOpenTable(((JSString id) => cb(id.toDart)).toJS);
    } catch (_) {}
  }
}
