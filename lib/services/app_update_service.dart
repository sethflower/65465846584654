import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AppUpdateInfo {
  final String version;
  final int buildNumber;
  final String downloadUrl;
  final bool force;
  final String notes;

  const AppUpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    required this.force,
    required this.notes,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      version: (json['version'] ?? '').toString(),
      buildNumber: _parseInt(json['build_number']),
      downloadUrl: (json['download_url'] ?? '').toString(),
      force: json['force'] == true,
      notes: (json['notes'] ?? '').toString(),
    );
  }

  static int _parseInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value.toString()) ?? 0;
  }
}

class AppUpdateService {
  static const String _manifestUrl = String.fromEnvironment(
    'APP_UPDATE_MANIFEST_URL',
    defaultValue: '',
  );

  Future<AppUpdateInfo?> checkForUpdate() async {
    if (_manifestUrl.trim().isEmpty) {
      return null;
    }

    final packageInfo = await PackageInfo.fromPlatform();
    final currentBuildNumber = int.tryParse(packageInfo.buildNumber) ?? 0;

    final uri = _addCacheBuster(Uri.parse(_manifestUrl));

    final response = await http.get(
      uri,
      headers: const {
        'Accept': 'application/json',
      },
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }

    final body = utf8.decode(response.bodyBytes).trim();

    if (body.isEmpty || body.startsWith('<')) {
      return null;
    }

    final decoded = jsonDecode(body);

    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final updateInfo = AppUpdateInfo.fromJson(decoded);

    if (updateInfo.buildNumber > currentBuildNumber &&
        updateInfo.downloadUrl.trim().isNotEmpty) {
      return updateInfo;
    }

    return null;
  }

  Future<void> openDownloadUrl(String downloadUrl) async {
    final uri = Uri.parse(downloadUrl);

    final opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );

    if (!opened) {
      throw Exception('Не удалось открыть ссылку для загрузки обновления.');
    }
  }

  Uri _addCacheBuster(Uri uri) {
    final params = Map<String, String>.from(uri.queryParameters);
    params['_t'] = DateTime.now().millisecondsSinceEpoch.toString();

    return uri.replace(queryParameters: params);
  }
}
