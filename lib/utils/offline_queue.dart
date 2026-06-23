import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'tracking_api.dart';

/// Менеджер офлайн-очереди
class OfflineQueue {
  static const String _boxName = 'offline_records';

  /// Инициализация Hive
  static Future<void> init() async {
    await Hive.initFlutter();
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox(_boxName);
    }
  }

  /// Добавить запись в очередь
  static Future<void> addRecord(Map<String, dynamic> record) async {
    try {
      await init();
      final box = Hive.box(_boxName);
      await box.add(record);
      print('✅ OfflineQueue: запис збережено локально');
    } catch (e) {
      print('⚠️ OfflineQueue.addRecord помилка: $e');
    }
  }

  /// Получить все локальные записи
  static Future<List<Map<String, dynamic>>> getPendingRecords() async {
    await init();
    final box = Hive.box(_boxName);
    return box.values.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Удалить все успешно синхронизированные записи
  static Future<void> clearSynced() async {
    await init();
    final box = Hive.box(_boxName);
    await box.clear();
  }

  /// Проверить, есть ли соединение
  static Future<bool> _hasConnection() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult.any((result) => result != ConnectivityResult.none);
  }

  /// Отправить все накопленные записи на сервер
  static Future<void> syncPending() async {
    try {
      if (!await _hasConnection()) {
        print('📡 Немає інтернету — синхронізація відкладена');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) return;

      await init();
      final box = Hive.box(_boxName);

      if (box.isEmpty) return;

      final keys = box.keys.toList();
      print('🔄 Спроба синхронізувати ${keys.length} записів...');

      for (final key in keys) {
        final value = box.get(key);
        if (value is! Map) {
          await box.delete(key);
          continue;
        }
        final record = Map<String, dynamic>.from(value);
        final response = await http.post(
          trackingApiUri('/add_record'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(record),
        );

        if (response.statusCode == 200) {
          print('✅ Синхронізовано запис: ${record['boxid']} / ${record['ttn']}');
          await box.delete(key);
        } else {
          print('⚠️ Не вдалося синхронізувати: ${response.statusCode} ${response.body}');
        }
      }

      if (box.isEmpty) {
        print('🎉 Усі офлайн-записи успішно синхронізовані');
      }
    } catch (e) {
      print('❌ OfflineQueue.syncPending помилка: $e');
    }
  }
}
