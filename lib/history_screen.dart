import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'utils/access_utils.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<dynamic> _records = [];
  List<dynamic> _filteredRecords = [];
  bool _isLoading = false;
  Map<String, dynamic> _accessInfo = {};

  // --- фильтры (только BoxID и TTN) ---
  final TextEditingController _boxidController = TextEditingController();
  final TextEditingController _ttnController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadAccess();
    _fetchHistory();
  }

  @override
  void dispose() {
    _boxidController.dispose();
    _ttnController.dispose();
    super.dispose();
  }

  Future<void> _loadAccess() async {
    final info = await getUserAccessInfo();
    setState(() => _accessInfo = info);
  }

  /// Форматує дату/час у локальну зону пристрою
  String formatDate(String isoString) {
    try {
      final localDate = DateTime.parse(isoString).toLocal();
      return DateFormat('dd.MM.yyyy HH:mm:ss').format(localDate);
    } catch (_) {
      return isoString;
    }
  }

  /// загрузка истории
  Future<void> _fetchHistory() async {
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token == null) {
      if (mounted) Navigator.pushReplacementNamed(context, '/');
      return;
    }

    try {
      final uri = Uri.parse('https://tracking-app.dclink.ua/get_history');
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
        setState(() {
          _records = data;
        });
        _applyFilters();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Помилка сервера: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Помилка зв’язку з сервером: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// применяем фильтры локально (только BoxID и TTN)
  void _applyFilters() {
    List<dynamic> filtered = List.from(_records);

    if (_boxidController.text.isNotEmpty) {
      filtered = filtered
          .where(
            (r) => r['boxid'].toString().contains(_boxidController.text.trim()),
          )
          .toList();
    }

    if (_ttnController.text.isNotEmpty) {
      filtered = filtered
          .where(
            (r) => r['ttn'].toString().contains(_ttnController.text.trim()),
          )
          .toList();
    }

    setState(() {
      _filteredRecords = filtered;
    });
  }

  void _clearFilters() {
    _boxidController.clear();
    _ttnController.clear();
    _applyFilters();
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Очистити історію?'),
        content: const Text('Ця дія видалить усі записи історії. Ви впевнені?'),
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
      final uri = Uri.parse('https://tracking-app.dclink.ua/clear_tracking');
      final response = await http.delete(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        setState(() {
          _records.clear();
          _filteredRecords.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Історію очищено ✅')),
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
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasActiveFilter =
        _boxidController.text.isNotEmpty || _ttnController.text.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Історія сканувань'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Оновити',
            onPressed: _fetchHistory,
          ),
          if (_accessInfo['canClearHistory'] == true)
            IconButton(
              icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
              tooltip: 'Очистити історію (адмін)',
              onPressed: _clearHistory,
            ),
        ],
      ),
      backgroundColor: const Color(0xFFF7F8FA),
      body: Column(
        children: [
          // ── Панель фільтрів ──
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: _filterField(
                    _boxidController,
                    'BoxID',
                    Icons.inventory_2_outlined,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _filterField(
                    _ttnController,
                    'TTN',
                    Icons.local_shipping_outlined,
                  ),
                ),
                if (hasActiveFilter) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: _clearFilters,
                    icon: const Icon(Icons.clear),
                    tooltip: 'Скинути фільтри',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.blueGrey,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── Лічильник ──
          if (!_isLoading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Знайдено записів: ${_filteredRecords.length}',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),

          const Divider(height: 1),

          // ── Список ──
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredRecords.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.inbox_outlined,
                                size: 56, color: Colors.grey.shade400),
                            const SizedBox(height: 12),
                            Text(
                              'Історія порожня',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey.shade600,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _fetchHistory,
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
                          itemCount: _filteredRecords.length,
                          itemBuilder: (context, index) {
                            final item = _filteredRecords[index];
                            final hasError = item['note'] != null &&
                                item['note'].toString().isNotEmpty;
                            return _historyCard(item, hasError);
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  // ── Карточка запису ──
  Widget _historyCard(dynamic item, bool hasError) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: hasError ? const Color(0xFFFFF1F1) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: hasError
              ? Colors.redAccent.withOpacity(0.35)
              : Colors.grey.withOpacity(0.15),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // BoxID — повний, на всю ширину
            _infoRow(
              icon: Icons.inventory_2,
              iconColor: Colors.blueGrey,
              label: 'BoxID',
              value: '${item['boxid'] ?? '—'}',
              bold: true,
            ),
            const SizedBox(height: 8),
            // TTN — повний, на всю ширину
            _infoRow(
              icon: Icons.local_shipping,
              iconColor: Colors.teal,
              label: 'TTN',
              value: '${item['ttn'] ?? '—'}',
            ),
            const Divider(height: 20),
            // Користувач
            _infoRow(
              icon: Icons.person_outline,
              iconColor: Colors.indigo,
              label: 'Користувач',
              value: '${item['user_name'] ?? '—'}',
              compact: true,
            ),
            const SizedBox(height: 6),
            // Дата/час
            _infoRow(
              icon: Icons.access_time,
              iconColor: Colors.deepPurple,
              label: 'Час',
              value: formatDate(item['datetime'] ?? ''),
              compact: true,
            ),
            // Примітка/помилка
            if (hasError) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline,
                        size: 18, color: Colors.redAccent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item['note'].toString(),
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Рядок інформації (текст не обрізається — переноситься) ──
  Widget _infoRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    bool bold = false,
    bool compact = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: iconColor, size: compact ? 17 : 19),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: TextStyle(
            fontSize: compact ? 13 : 14,
            color: Colors.grey.shade600,
            fontWeight: FontWeight.w500,
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              fontSize: compact ? 13.5 : 15,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              color: const Color(0xFF1A2233),
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }

  // ── Поле фільтра ──
  Widget _filterField(
    TextEditingController controller,
    String label,
    IconData icon,
  ) {
    return TextField(
      controller: controller,
      onChanged: (_) => _applyFilters(),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.withOpacity(0.3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.withOpacity(0.25)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.teal, width: 1.6),
        ),
      ),
    );
  }
}