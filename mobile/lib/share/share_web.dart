import 'dart:js_interop';

@JS('trilingShare.share')
external JSPromise<JSString> _share(JSString title, JSString text);

@JS('trilingShare.download')
external JSString _download(JSString name, JSString text);

/// Deljenje i čuvanje ruke u pregledaču (web/share.js).
class HandShare {
  /// "shared", "copied", "cancel" ili "failed"
  static Future<String> share(String title, String text) async {
    try {
      return (await _share(title.toJS, text.toJS).toDart).toDart;
    } catch (_) {
      return 'failed';
    }
  }

  static String download(String name, String text) {
    try {
      return _download(name.toJS, text.toJS).toDart;
    } catch (_) {
      return 'failed';
    }
  }
}
