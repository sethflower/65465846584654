import 'dart:convert';

import 'package:http/http.dart' as http;

import 'scanpak_auth.dart';

enum ScanpakUserRole { admin, operator }

extension ScanpakUserRoleX on ScanpakUserRole {
  String get label {
    switch (this) {
      case ScanpakUserRole.admin:
        return 'Адмін';
      case ScanpakUserRole.operator:
        return 'Оператор';
    }
  }

  String get description {
    switch (this) {
      case ScanpakUserRole.admin:
        return 'Повний доступ до функцій та керування користувачами';
      case ScanpakUserRole.operator:
        return 'Додавання записів та базовий функціонал';
    }
  }

  int get level {
    switch (this) {
      case ScanpakUserRole.admin:
        return 1;
      case ScanpakUserRole.operator:
        return 0;
    }
  }
}

ScanpakUserRole parseScanpakUserRole(String? value) {
  switch (value) {
    case 'admin':
      return ScanpakUserRole.admin;
    case 'operator':
    default:
      return ScanpakUserRole.operator;
  }
}

class ScanpakManagedUser {
  const ScanpakManagedUser({
    required this.id,
    required this.surname,
    required this.role,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String surname;
  final ScanpakUserRole role;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  ScanpakManagedUser copyWith({ScanpakUserRole? role, bool? isActive}) {
    return ScanpakManagedUser(
      id: id,
      surname: surname,
      role: role ?? this.role,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  factory ScanpakManagedUser.fromJson(Map<String, dynamic> json) {
    return ScanpakManagedUser(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      surname: json['surname']?.toString() ?? 'Невідомий користувач',
      role: parseScanpakUserRole(json['role']?.toString()),
      isActive: json['is_active'] == true,
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class ScanpakPendingUser {
  const ScanpakPendingUser({
    required this.id,
    required this.surname,
    required this.createdAt,
  });

  final int id;
  final String surname;
  final DateTime createdAt;

  factory ScanpakPendingUser.fromJson(Map<String, dynamic> json) {
    return ScanpakPendingUser(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      surname: json['surname']?.toString() ?? 'Невідомий користувач',
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class ScanpakApiException implements Exception {
  ScanpakApiException(this.message, this.statusCode);

  final String message;
  final int statusCode;

  @override
  String toString() => 'ScanpakApiException($statusCode): $message';
}

class ScanpakUserApi {
  const ScanpakUserApi._();

  static Uri _uri(String path, [Map<String, String>? query]) {
    return Uri.https(kScanpakApiHost, '$kScanpakBasePath$path', query);
  }

  static Map<String, String> _headers({String? token}) {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  static dynamic _decodeBody(http.Response response) {
    if (response.body.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(response.body);
    } catch (_) {
      return null;
    }
  }

  static String _extractMessage(dynamic body, int statusCode) {
    if (body is Map<String, dynamic>) {
      final detail = body['detail'] ?? body['message'];
      if (detail is String && detail.isNotEmpty) {
        return detail;
      }
    }
    return 'Помилка сервера ($statusCode)';
  }

  static Never _throwError(http.Response response) {
    final body = _decodeBody(response);
    final message = _extractMessage(body, response.statusCode);
    throw ScanpakApiException(message, response.statusCode);
  }

  static Future<List<ScanpakPendingUser>> fetchPendingUsers(
    String token,
  ) async {
    final response = await http.get(
      _uri('/admin/registration_requests'),
      headers: _headers(token: token),
    );

    if (response.statusCode == 200) {
      final body = _decodeBody(response);
      if (body is List) {
        return body
            .map(
              (item) => ScanpakPendingUser.fromJson(
                item is Map<String, dynamic>
                    ? item
                    : Map<String, dynamic>.from(
                        (item as Map).map(
                          (key, value) => MapEntry(key.toString(), value),
                        ),
                      ),
              ),
            )
            .toList(growable: false);
      }
      return const [];
    }

    _throwError(response);
  }

  static Future<void> approvePendingUser({
    required String token,
    required int requestId,
    required ScanpakUserRole role,
  }) async {
    final response = await http.post(
      _uri('/admin/registration_requests/$requestId/approve'),
      headers: _headers(token: token),
      body: jsonEncode({'role': role.name}),
    );

    if (response.statusCode == 200) {
      return;
    }

    _throwError(response);
  }

  static Future<void> rejectPendingUser({
    required String token,
    required int requestId,
  }) async {
    final response = await http.post(
      _uri('/admin/registration_requests/$requestId/reject'),
      headers: _headers(token: token),
    );

    if (response.statusCode == 200) {
      return;
    }

    _throwError(response);
  }

  static Future<List<ScanpakManagedUser>> fetchUsers(String token) async {
    final response = await http.get(
      _uri('/admin/users'),
      headers: _headers(token: token),
    );

    if (response.statusCode == 200) {
      final body = _decodeBody(response);
      if (body is List) {
        return body
            .map(
              (item) => ScanpakManagedUser.fromJson(
                item is Map<String, dynamic>
                    ? item
                    : Map<String, dynamic>.from(
                        (item as Map).map(
                          (key, value) => MapEntry(key.toString(), value),
                        ),
                      ),
              ),
            )
            .toList(growable: false);
      }
      return const [];
    }

    _throwError(response);
  }

  static Future<ScanpakManagedUser> updateUser({
    required String token,
    required int userId,
    ScanpakUserRole? role,
    bool? isActive,
  }) async {
    final payload = <String, dynamic>{};
    if (role != null) {
      payload['role'] = role.name;
    }
    if (isActive != null) {
      payload['is_active'] = isActive;
    }

    if (payload.isEmpty) {
      throw ScanpakApiException('Немає даних для оновлення', 400);
    }

    final response = await http.patch(
      _uri('/admin/users/$userId'),
      headers: _headers(token: token),
      body: jsonEncode(payload),
    );

    if (response.statusCode == 200) {
      final body = _decodeBody(response);
      if (body is Map<String, dynamic>) {
        return ScanpakManagedUser.fromJson(body);
      }
      throw ScanpakApiException(
        'Некоректна відповідь сервера',
        response.statusCode,
      );
    }

    _throwError(response);
  }

  static Future<void> deleteUser({
    required String token,
    required int userId,
  }) async {
    final response = await http.delete(
      _uri('/admin/users/$userId'),
      headers: _headers(token: token),
    );

    if (response.statusCode == 200) {
      return;
    }

    _throwError(response);
  }

  static Future<Map<ScanpakUserRole, String>> fetchRolePasswords(
    String token,
  ) async {
    final response = await http.get(
      _uri('/admin/role-passwords'),
      headers: _headers(token: token),
    );

    if (response.statusCode == 200) {
      final body = _decodeBody(response);
      if (body is Map) {
        final result = <ScanpakUserRole, String>{};
        body.forEach((key, value) {
          final role = parseScanpakUserRole(key.toString());
          result[role] = value == null ? '' : value.toString();
        });
        return result;
      }
      return const {};
    }

    _throwError(response);
  }

  static Future<void> updateRolePassword({
    required String token,
    required ScanpakUserRole role,
    required String password,
  }) async {
    final response = await http.post(
      _uri('/admin/role-passwords/${role.name}'),
      headers: _headers(token: token),
      body: jsonEncode({'password': password.trim()}),
    );

    if (response.statusCode == 200) {
      return;
    }

    _throwError(response);
  }
}
