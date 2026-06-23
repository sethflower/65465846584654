import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'utils/access_utils.dart';

class ErrorsScreen extends StatefulWidget {
  const ErrorsScreen({super.key});

  @override
  State<ErrorsScreen> createState() => _ErrorsScreenState();
}

class _ErrorsScreenState extends State<ErrorsScreen> {
  List<dynamic> _errors = [];
  bool _isLoading = false;
  bool _canClear = false; // адмін або спец-користувач на помилки

  @override
  void initState() {
    super.initState();
    _loadAccess();
    _fetchErrors();
  }

  Future<void> _loadAccess() async {
    final info = await getUserAccessInfo();
    // Разрешаем удаление для админа (level == 1) и оператора (level == 0)
    setState(() {
      _canClear = (info['level'] == 1) || (info['level'] == 0);
    });
  }

  String _formatDate(String isoString) {
    try {
      final localDate = DateTime.parse(isoString).toLocal();
      return DateFormat('dd.MM.yyyy HH:mm:ss').format(localDate);
    } catch (_) {
      return isoString;
    }
  }

  Future<void> _fetchErrors() async {
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');

    if (token == null) {
      if (mounted) Navigator.pushReplacementNamed(context, '/');
      return;
    }

    try {
      final uri = Uri.parse(
        'http://173.242.53.38:10000/get_errors',
      );
      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        data.sort((a, b) {
          final da = DateTime.tryParse(a['datetime'] ?? '') ?? DateTime(2000);
          final db = DateTime.tryParse(b['datetime'] ?? '') ?? DateTime(2000);
          return db.compareTo(da);
        });
        setState(() => _errors = data);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Помилка сервера: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Помилка з’єднання: $e')));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _clearErrorsAll() async {
    if (!_canClear) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Очистити журнал помилок?'),
        content: const Text(
          'Ця дія видалить усі записи про помилки. Ви впевнені?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Скасувати'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Так, видалити'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');

    try {
      final uri = Uri.parse(
        'http://173.242.53.38:10000/clear_errors',
      );
      final response = await http.delete(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        setState(() => _errors.clear());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Журнал помилок очищено ✅')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не вдалося очистити: ${response.statusCode}'),
          ),
        );
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Помилка зв’язку з сервером')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteErrorById(int id) async {
    if (!_canClear) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Видалити помилку?'),
        content: Text('ID: $id\nЦю помилку буде видалено з бази. Продовжити?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Скасувати'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Видалити'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');

    try {
      final uri = Uri.parse(
        'http://173.242.53.38:10000/delete_error/$id',
      );
      final res = await http.delete(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        // Удаляем локально без полного рефреша
        setState(() {
          _errors.removeWhere((e) => e['id'] == id);
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Помилку #$id видалено ✅')));
      } else if (res.statusCode == 404) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Помилка не знайдена (404)')),
        );
        // Обновим список, вдруг рассинхрон
        _fetchErrors();
      } else if (res.statusCode == 403) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('У вас немає прав на видалення')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не вдалося видалити: ${res.statusCode}')),
        );
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Помилка зв’язку з сервером')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Журнал помилок'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchErrors,
            tooltip: 'Оновити',
          ),
          if (_canClear)
            IconButton(
              icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
              onPressed: _clearErrorsAll,
              tooltip: 'Очистити всі',
            ),
        ],
      ),
      backgroundColor: const Color(0xFFF7F8FA),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errors.isEmpty
          ? const Center(
              child: Text(
                'Журнал помилок порожній',
                style: TextStyle(fontSize: 18, color: Colors.black54),
              ),
            )
          : ListView.builder(
              itemCount: _errors.length,
              itemBuilder: (context, index) {
                final e = _errors[index];

                final reason =
                    e['error_message'] ??
                    e['reason'] ??
                    e['note'] ??
                    e['message'] ??
                    e['error'] ??
                    'Причина не вказана';

                final id = e['id'] is int
                    ? e['id'] as int
                    : int.tryParse('${e['id']}');

                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  color: const Color(0xFFFFEBEE),
                  child: InkWell(
                    onTap: (_canClear && id != null)
                        ? () => _deleteErrorById(id)
                        : null,
                    child: ListTile(
                      leading: const Icon(Icons.error, color: Colors.redAccent),
                      title: Text(
                        reason,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.redAccent,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('📦 BoxID: ${e['boxid'] ?? '-'}'),
                            Text('🚚 TTN: ${e['ttn'] ?? '-'}'),
                            Text('👤 ${e['user_name'] ?? '-'}'),
                            Text('🕓 ${_formatDate(e['datetime'] ?? '')}'),
                          ],
                        ),
                      ),
                      trailing: (_canClear && id != null)
                          ? IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.redAccent,
                              ),
                              tooltip: 'Видалити цей запис',
                              onPressed: () => _deleteErrorById(id),
                            )
                          : null,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
