import 'dart:js_interop';

@JS('trilingPush.status')
external JSString _status();

@JS('trilingPush.requestPermission')
external JSPromise<JSString> _requestPermission();

@JS('trilingPush.subscribe')
external JSPromise<JSString> _subscribe(JSString key);

@JS('trilingPush.current')
external JSPromise<JSString> _current();

@JS('trilingPush.unsubscribe')
external JSPromise<JSString> _unsubscribe();

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

  /// Pitanje za dozvolu — pozvati odmah na dodir (pre bilo kakvog čekanja). Vraća "granted", "denied"…
  static Future<String> requestPermission() async {
    try {
      return (await _requestPermission().toDart).toDart;
    } catch (_) {
      return 'denied';
    }
  }

  /// Pretplaćuje uređaj (posle dozvole); vraća pretplatu kao JSON tekst ili prazno.
  static Future<String> subscribe(String publicKey) async {
    try {
      return (await _subscribe(publicKey.toJS).toDart).toDart;
    } catch (_) {
      return '';
    }
  }

  /// Trenutna pretplata ovog uređaja (JSON) ili prazno ako obaveštenja nisu uključena.
  static Future<String> current() async {
    try {
      return (await _current().toDart).toDart;
    } catch (_) {
      return '';
    }
  }

  /// Isključuje obaveštenja na ovom uređaju; vraća adresu odjavljene pretplate ili prazno.
  static Future<String> unsubscribe() async {
    try {
      return (await _unsubscribe().toDart).toDart;
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
