import 'dart:convert';

import 'package:http/http.dart' as http;

const String kScanpakApiHost = 'tracking-api-b4jb.onrender.com';
const String kScanpakBasePath = '/scanpak';

class ScanpakAuthApi {
  const ScanpakAuthApi._();

  static Uri _uri(String path) => Uri.https(kScanpakApiHost, '$kScanpakBasePath$path');

  static Map<String, String> _headers() => const {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  static String _extractMessage(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final detail = body['detail'] ?? body['message'];
        if (detail is String && detail.isNotEmpty) {
          return detail;
        }
      }
    } catch (_) {
      // ignore
    }
    return 'Помилка (${response.statusCode})';
  }

  static Future<Map<String, dynamic>> login(
    String surname,
    String password,
  ) async {
    final response = await http.post(
      _uri('/login'),
      headers: _headers(),
      body: jsonEncode({
        'surname': surname,
        'password': password,
      }),
    );

    if (response.statusCode != 200) {
      throw ScanpakAuthException(_extractMessage(response), response.statusCode);
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const ScanpakAuthException(
        'Некоректна відповідь сервера',
        500,
      );
    }
    return decoded;
  }

  static Future<void> register(String surname, String password) async {
    final response = await http.post(
      _uri('/register'),
      headers: _headers(),
      body: jsonEncode({
        'surname': surname,
        'password': password,
      }),
    );

    if (response.statusCode == 200) {
      return;
    }
    throw ScanpakAuthException(_extractMessage(response), response.statusCode);
  }
}

class ScanpakAuthException implements Exception {
  const ScanpakAuthException(this.message, this.statusCode);

  final String message;
  final int statusCode;

  @override
  String toString() => 'ScanpakAuthException($statusCode): $message';
}
