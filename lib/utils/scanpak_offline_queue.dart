import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'scanpak_auth.dart';

class ScanpakOfflineQueue {
  static const String _boxName = 'scanpak_offline_scans';

  static Future<void> init() async {
    await Hive.initFlutter();
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox(_boxName);
    }
  }

  static Future<void> addRecord(String digits) async {
    if (digits.isEmpty) return;
    try {
      await init();
      final box = Hive.box(_boxName);
      await box.add({
        'parcel_number': digits,
        'stored_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      print('⚠️ ScanpakOfflineQueue.addRecord error: $e');
    }
  }

  static Future<bool> contains(String digits) async {
    if (digits.isEmpty) return false;
    try {
      await init();
      final box = Hive.box(_boxName);
      return box.values.any((value) {
        if (value is! Map) return false;
        final stored = value['parcel_number']?.toString();
        return stored != null && stored.trim() == digits.trim();
      });
    } catch (e) {
      print('⚠️ ScanpakOfflineQueue.contains error: $e');
      return false;
    }
  }
  
  static Future<bool> _hasConnection() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult != ConnectivityResult.none;
  }

  static Future<void> syncPending() async {
    try {
      if (!await _hasConnection()) {
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('scanpak_token');
      if (token == null) return;

      await init();
      final box = Hive.box(_boxName);
      if (box.isEmpty) return;

      final keys = box.keys.toList();
      for (final key in keys) {
        final value = box.get(key);
        if (value is! Map) continue;
        final digits = value['parcel_number']?.toString();
        if (digits == null || digits.isEmpty) {
          await box.delete(key);
          continue;
        }

        final uri = Uri.https(kScanpakApiHost, '$kScanpakBasePath/scans');
        final response = await http.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'parcel_number': digits}),
        );

        if (response.statusCode == 200) {
          await box.delete(key);
        }
      }
    } catch (e) {
      print('❌ ScanpakOfflineQueue.syncPending error: $e');
    }
  }
}
