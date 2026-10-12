import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

class ApiException implements Exception {
  final String message;
  final int status;
  ApiException(this.message, this.status);
  @override
  String toString() => message;
}

/// Jednostavan REST klijent. Server vraća poruke grešaka na srpskom,
/// pa se one prikazuju korisniku direktno.
class Api {
  String? token;
  void Function(String message)? onUnauthorized;

  Future<dynamic> get(String path) => _send('GET', path);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body);

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final req = http.Request(method, Uri.parse('$apiBaseUrl/api$path'));
    req.headers['content-type'] = 'application/json';
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) req.body = jsonEncode(body);
    http.StreamedResponse streamed;
    try {
      streamed = await req.send().timeout(const Duration(seconds: 15));
    } catch (_) {
      throw ApiException('Nema veze sa serverom. Proverite internet.', 0);
    }
    final res = await http.Response.fromStream(streamed);
    final data = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      final msg = data is Map && data['message'] != null
          ? (data['message'] is List ? (data['message'] as List).first : data['message']).toString()
          : 'Greška (${res.statusCode})';
      if ((res.statusCode == 401 || res.statusCode == 403) && token != null && path != '/auth/login') {
        onUnauthorized?.call(msg);
      }
      throw ApiException(msg, res.statusCode);
    }
    return data;
  }
}
