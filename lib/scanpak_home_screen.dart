import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils/scanpak_auth.dart';
import 'utils/scanpak_offline_queue.dart';
import 'utils/scanpak_user_management.dart';

class ScanpakHomeScreen extends StatefulWidget {
  const ScanpakHomeScreen({super.key});

  @override
  State<ScanpakHomeScreen> createState() => _ScanpakHomeScreenState();
}

class _ScanpakHomeScreenState extends State<ScanpakHomeScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _numberController = TextEditingController();
  final FocusNode _numberFocus = FocusNode();

  final TextEditingController _parcelFilterController = TextEditingController();
  final TextEditingController _userFilterController = TextEditingController();
  final TextEditingController _statsUserFilterController = TextEditingController();

  DateTime? _selectedDate;
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;

  DateTime? _statsStartDate;
  DateTime? _statsEndDate;

  final AudioPlayer _audioPlayer = AudioPlayer();

  late final TabController _tabController;
  late final Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  String? _userName;
  ScanpakUserRole? _userRole;
  String _status = '';
  bool _isOnline = true;
  bool _isLoadingHistory = false;
  List<_ScanpakRecord> _records = const [];
  List<_ScanpakRecord> _filteredRecords = const [];
  List<_ScanpakRecord> _statsRecords = const [];
  Map<String, int> _userStats = const {};
  Map<DateTime, int> _dailyStats = const {};
  _ScanpakRecord? _latestStatsRecord;
  String _topUser = '—';
  int _topUserCount = 0;

  bool get _isOperator => _userRole == ScanpakUserRole.operator;
  bool get _isAdmin => _userRole == ScanpakUserRole.admin;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging && _tabController.index == 0) {
          _focusInput();
        }
      });
    _connectivity = Connectivity();
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      (results) async {
        final online =
            results.isNotEmpty && results.first != ConnectivityResult.none;
        if (mounted) setState(() => _isOnline = online);
        if (online) {
          await ScanpakOfflineQueue.syncPending();
        }
      },
    );
    _initConnectivityStatus();
    final now = DateTime.now();
    _statsEndDate = DateTime(now.year, now.month, now.day);
    _statsStartDate = _statsEndDate?.subtract(const Duration(days: 6));
    _loadUser();
    _fetchHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusInput());
  }

  @override
  void dispose() {
    _tabController.dispose();
    _numberController.dispose();
    _numberFocus.dispose();
    _parcelFilterController.dispose();
    _userFilterController.dispose();
    _statsUserFilterController.dispose();
    _connectivitySubscription?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _initConnectivityStatus() async {
    final result = await _connectivity.checkConnectivity();
    final online = result != ConnectivityResult.none;
    if (mounted) setState(() => _isOnline = online);
    if (online) {
      await ScanpakOfflineQueue.syncPending();
    }
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _userName = prefs.getString('scanpak_user_name');
      final storedRole = prefs.getString('scanpak_user_role');
      _userRole = storedRole == null ? null : parseScanpakUserRole(storedRole);
    });
    _ensureDefaultUserFilters();
    _applyFilters();
    _applyStatsFilters();
  }

  Future<void> _fetchHistory() async {
    setState(() => _isLoadingHistory = true);
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('scanpak_token');
    if (token == null) {
      if (mounted) Navigator.pushReplacementNamed(context, '/');
      if (mounted) setState(() => _isLoadingHistory = false);
      return;
    }

    try {
      final uri = scanpakApiUri('/history');
      final response = await http.get(
        uri,
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode != 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Не вдалося отримати історію (${response.statusCode})',
              ),
            ),
          );
        }
        return;
      }

      final parsed = _ScanpakRecord.decodeList(response.body);
      setState(() {
        _records = parsed;
      });
      _applyFilters();
      _applyStatsFilters();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Помилка зв’язку з сервером: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  void _focusInput() {
    if (_numberFocus.canRequestFocus) {
      _numberFocus.requestFocus();
    }
  }

  void _ensureDefaultUserFilters() {
    if (_isOperator && _userName?.isNotEmpty == true) {
      if (_userFilterController.text != _userName) {
        _userFilterController.text = _userName!;
      }
      if (_statsUserFilterController.text != _userName) {
        _statsUserFilterController.text = _userName!;
      }
      return;
    }

    if (_isAdmin) {
      return;
    }

    if (_userName?.isNotEmpty == true) {
      if (_userFilterController.text.isEmpty) {
        _userFilterController.text = _userName!;
      }
      if (_statsUserFilterController.text.isEmpty) {
        _statsUserFilterController.text = _userName!;
      }
    }
  }

  String _effectiveUserFilter(TextEditingController controller) {
    if (_isOperator && _userName?.isNotEmpty == true) {
      if (controller.text != _userName) {
        controller.text = _userName!;
      }
      return _userName!;
    }
    return controller.text.trim();
  }

  String _sanitizeNumber(String value) {
    return value.replaceAll(RegExp(r'[^0-9]'), '');
  }

  Future<void> _playSuccessSound() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('sounds/success.wav'));
    } catch (_) {
      // ignore audio issues silently
    }
  }

  void _onChanged(String value) {
    if (_status.isNotEmpty) {
      setState(() => _status = '');
    }
  }

  Future<void> _handleSubmit([String? raw]) async {
    final digits = _sanitizeNumber(raw ?? _numberController.text);
    if (digits.isEmpty) {
      setState(() => _status = 'Не знайшли цифр у введенні');
      _focusInput();
      return;
    }

    if (await _isDuplicate(digits)) {
      setState(() => _status = 'Увага, це дублікат. Не збережено');
      _numberController.clear();
      _focusInput();
      return;
    }

    setState(() => _status =
        _isOnline ? 'Відправляємо...' : 'Немає зв’язку — збережемо локально');
    try {
      final record = await _sendScanToBackend(digits);
      setState(() {
        _records = <_ScanpakRecord>[record, ..._records];
        _status =
            'Збережено для ${record.user} о ${DateFormat('HH:mm').format(record.timestamp.toLocal())}';
      });
      _playSuccessSound();
      _applyFilters();
      _applyStatsFilters();
    } catch (_) {
      await ScanpakOfflineQueue.addRecord(digits);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          const SnackBar(
            content: Text('Немає зв’язку або сервер недоступний. Збережено локально.'),
          ),
        );
      }
      setState(() => _status = '📦 Офлайн: номер $digits збережено локально');
    }

    await ScanpakOfflineQueue.syncPending();
    _numberController.clear();
    _focusInput();
  }

  Future<bool> _isDuplicate(String digits) async {
    final alreadyScanned =
        _records.any((existing) => existing.number.trim() == digits.trim());
    if (alreadyScanned) return true;

    return ScanpakOfflineQueue.contains(digits.trim());
  }
  
  Future<_ScanpakRecord> _sendScanToBackend(String digits) async {
    if (!_isOnline) {
      throw Exception('Offline');
    }

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('scanpak_token');
    if (token == null) {
      if (mounted) Navigator.pushReplacementNamed(context, '/');
      throw Exception('Немає токена авторизації');
    }

    final uri = scanpakApiUri('/scans');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'parcel_number': digits}),
    );

    if (response.statusCode == 401) {
      if (mounted) Navigator.pushReplacementNamed(context, '/');
      throw Exception('Сесію завершено. Увійдіть знову');
    }

    if (response.statusCode != 200) {
      throw Exception('Не вдалося зберегти: ${response.statusCode}');
    }

    return _ScanpakRecord.fromResponse(response.body);
  }

  void _applyFilters() {
    _ensureDefaultUserFilters();
    List<_ScanpakRecord> filtered = List.of(_records);

    if (_parcelFilterController.text.isNotEmpty) {
      filtered = filtered
          .where((r) => r.number.contains(_parcelFilterController.text.trim()))
          .toList();
    }

    final userFilter = _effectiveUserFilter(_userFilterController);
    if (userFilter.isNotEmpty) {
      filtered = filtered
          .where(
            (r) => r.user.toLowerCase().contains(
              userFilter.toLowerCase(),
            ),
          )
          .toList();
    }

    if (_selectedDate != null) {
      filtered = filtered.where((r) {
        final local = r.timestamp.toLocal();
        return local.year == _selectedDate!.year &&
            local.month == _selectedDate!.month &&
            local.day == _selectedDate!.day;
      }).toList();
    }

    if (_startTime != null || _endTime != null) {
      filtered = filtered.where((r) {
        final local = r.timestamp.toLocal();
        final time = TimeOfDay.fromDateTime(local);

        bool afterStart = true;
        bool beforeEnd = true;

        if (_startTime != null) {
          afterStart =
              time.hour > _startTime!.hour ||
              (time.hour == _startTime!.hour &&
                  time.minute >= _startTime!.minute);
        }

        if (_endTime != null) {
          beforeEnd =
              time.hour < _endTime!.hour ||
              (time.hour == _endTime!.hour && time.minute <= _endTime!.minute);
        }

        return afterStart && beforeEnd;
      }).toList();
    }

    setState(() => _filteredRecords = filtered);
  }

  void _applyStatsFilters() {
    _ensureDefaultUserFilters();
    List<_ScanpakRecord> filtered = List.of(_records);

    final userFilter = _effectiveUserFilter(_statsUserFilterController);
    if (userFilter.isNotEmpty) {
      filtered = filtered
          .where(
            (r) => r.user.toLowerCase().contains(userFilter.toLowerCase()),
          )
          .toList();
    }

    if (_statsStartDate != null) {
      final start = DateTime(
        _statsStartDate!.year,
        _statsStartDate!.month,
        _statsStartDate!.day,
      );
      filtered = filtered
          .where((r) => r.timestamp.toLocal().isAfter(start) ||
              r.timestamp.toLocal().isAtSameMomentAs(start))
          .toList();
    }

    if (_statsEndDate != null) {
      final end = DateTime(
        _statsEndDate!.year,
        _statsEndDate!.month,
        _statsEndDate!.day + 1,
      );
      filtered =
          filtered.where((r) => r.timestamp.toLocal().isBefore(end)).toList();
    }

    filtered.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    final userCounts = <String, int>{};
    final dailyCounts = <DateTime, int>{};

    for (final record in filtered) {
      userCounts.update(record.user, (value) => value + 1, ifAbsent: () => 1);

      final dateKey = DateTime(
        record.timestamp.toLocal().year,
        record.timestamp.toLocal().month,
        record.timestamp.toLocal().day,
      );
      dailyCounts.update(dateKey, (value) => value + 1, ifAbsent: () => 1);
    }

    final topUserEntry = userCounts.entries
        .fold<MapEntry<String, int>?>(null, (previous, element) {
      if (previous == null || element.value > previous.value) {
        return element;
      }
      return previous;
    });

    final limitedDaily = (dailyCounts.entries.toList()
          ..sort((a, b) => b.key.compareTo(a.key)))
        .take(7);

    setState(() {
      _statsRecords = filtered;
      _userStats = userCounts;
      _dailyStats = Map.fromEntries(limitedDaily);
      _latestStatsRecord = filtered.isEmpty ? null : filtered.first;
      _topUser = topUserEntry?.key ?? '—';
      _topUserCount = topUserEntry?.value ?? 0;
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: DateTime(2024),
      lastDate: now,
      locale: const Locale('uk', 'UA'),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
      _applyFilters();
    }
  }

  Future<void> _pickTime(bool isStart) async {
    final now = TimeOfDay.now();
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? (_startTime ?? now) : (_endTime ?? now),
      helpText: isStart ? 'Початковий час' : 'Кінцевий час',
      cancelText: 'Скасувати',
      confirmText: 'OK',
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startTime = picked;
        } else {
          _endTime = picked;
        }
      });
      _applyFilters();
    }
  }

  void _clearFilters() {
    _parcelFilterController.clear();
    _userFilterController.text = _isOperator ? (_userName ?? '') : '';
    _selectedDate = null;
    _startTime = null;
    _endTime = null;
    _statsUserFilterController.text = _isOperator ? (_userName ?? '') : '';
    final now = DateTime.now();
    _statsEndDate = DateTime(now.year, now.month, now.day);
    _statsStartDate = _statsEndDate?.subtract(const Duration(days: 6));
    _applyFilters();
    _applyStatsFilters();
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('scanpak_token');
    await prefs.remove('scanpak_user_name');
    await prefs.remove('scanpak_user_role');
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('СканПак'),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Вийти',
              onPressed: _logout,
            ),
          ],
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: 'Сканування'),
              Tab(text: 'Історія'),
              Tab(text: 'Статистика'),
            ],
          ),
        ),
        body: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              color: _isOnline ? Colors.green.shade600 : Colors.red.shade600,
              padding: const EdgeInsets.all(6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isOnline ? Icons.wifi : Icons.wifi_off,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isOnline
                        ? '🟢 Підключення активне'
                        : '🔴 Немає зв’язку з сервером',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildScanTab(theme),
                  _buildHistoryTab(theme),
                  _buildStatsTab(theme),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Сканування відправлень', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Відскануйте або введіть номер — після "Enter" скан зафіксується, а поле очиститься',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.grey[700],
            ),
          ),
          const SizedBox(height: 24),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.qr_code_scanner, color: Colors.blue),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _userName == null
                              ? 'Сканування без імені'
                              : 'Оператор: $_userName',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _numberController,
                    focusNode: _numberFocus,
                    autofocus: true,
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Номер посилки',
                      helperText:
                          'Відскануйте BoxID',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: _onChanged,
                    onSubmitted: _handleSubmit,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => _handleSubmit(),
                    icon: const Icon(Icons.save),
                    label: const Text('Зберегти скан'),
                  ),
                  if (_status.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _status,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.green[700],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryTab(ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _filterField(_parcelFilterController, 'Номер'),
              _filterField(
                _userFilterController,
                'Користувач',
                enabled: !_isOperator,
              ),
              ElevatedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.date_range),
                label: Text(
                  _selectedDate == null
                      ? 'Дата'
                      : DateFormat('dd.MM.yyyy').format(_selectedDate!),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () => _pickTime(true),
                icon: const Icon(Icons.access_time),
                label: Text(
                  _startTime == null ? 'Початок' : _startTime!.format(context),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () => _pickTime(false),
                icon: const Icon(Icons.timelapse),
                label: Text(
                  _endTime == null ? 'Кінець' : _endTime!.format(context),
                ),
              ),
              TextButton.icon(
                onPressed: _clearFilters,
                icon: const Icon(Icons.clear),
                label: const Text('Скинути'),
              ),
              IconButton(
                tooltip: 'Оновити',
                onPressed: _fetchHistory,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _isLoadingHistory
              ? const Center(child: CircularProgressIndicator())
              : _filteredRecords.isEmpty
              ? const Center(child: Text('Історія порожня'))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _filteredRecords.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final record = _filteredRecords[index];
                    final localTime = record.timestamp.toLocal();
                    final date = DateFormat('dd.MM.yyyy').format(localTime);
                    final time = DateFormat('HH:mm').format(localTime);

                    return Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 1,
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.inventory_2,
                                  color: Colors.blue,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Номер: ${record.number}',
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ),
                                Text(
                                  '$date • $time',
                                  style: theme.textTheme.labelMedium,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Користувач: ${record.user}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.grey[700],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _filterField(
    TextEditingController controller,
    String label, {
    bool enabled = true,
    String? helperText,
  }) {
    return SizedBox(
      width: 150,
      child: TextField(
        controller: controller,
        onChanged: (_) => _applyFilters(),
        enabled: enabled,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          helperText: helperText,
        ),
      ),
    );
  }

  Widget _buildStatsTab(ThemeData theme) {
    final dateRangeLabel = _statsStartDate == null && _statsEndDate == null
        ? 'Усі дні'
        : '${_statsStartDate == null ? '—' : DateFormat('dd.MM.yyyy').format(_statsStartDate!)} – ${_statsEndDate == null ? '—' : DateFormat('dd.MM.yyyy').format(_statsEndDate!)}';

    final sortedUsers = _userStats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final sortedDaily = _dailyStats.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));

    return _isLoadingHistory
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bar_chart, color: Colors.blue),
                    const SizedBox(width: 8),
                    Text(
                      'Статистика сканувань',
                      style: theme.textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 200,
                      child: TextField(
                        controller: _statsUserFilterController,
                        enabled: !_isOperator,
                        onChanged: (_) => _applyStatsFilters(),
                        decoration: InputDecoration(
                          labelText: 'Користувач',
                          helperText: _isOperator
                              ? 'Показано лише ваші скани'
                              : 'Введіть користувача',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _pickStatsDate(isStart: true),
                      icon: const Icon(Icons.calendar_today),
                      label: Text(
                        _statsStartDate == null
                            ? 'Початок'
                            : DateFormat('dd.MM.yyyy').format(_statsStartDate!),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _pickStatsDate(isStart: false),
                      icon: const Icon(Icons.event),
                      label: Text(
                        _statsEndDate == null
                            ? 'Кінець'
                            : DateFormat('dd.MM.yyyy').format(_statsEndDate!),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Оновити дані',
                      onPressed: _fetchHistory,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Діапазон: $dateRangeLabel',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _statCard(
                      theme: theme,
                      title: 'Всього сканів',
                      value: _statsRecords.length.toString(),
                      icon: Icons.inventory_2,
                      color: Colors.indigo,
                    ),
                    _statCard(
                      theme: theme,
                      title: 'Унікальних користувачів',
                      value: _userStats.length.toString(),
                      icon: Icons.people_alt,
                      color: Colors.teal,
                    ),
                    _statCard(
                      theme: theme,
                      title: 'Лідер',
                      value: _topUserCount == 0
                          ? '—'
                          : '$_topUser ($_topUserCount)',
                      icon: Icons.emoji_events,
                      color: Colors.orange,
                    ),
                    _statCard(
                      theme: theme,
                      title: 'Останній скан',
                      value: _latestStatsRecord == null
                          ? '—'
                          : DateFormat('dd.MM • HH:mm')
                              .format(_latestStatsRecord!.timestamp.toLocal()),
                      icon: Icons.access_time,
                      color: Colors.green,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.leaderboard, color: Colors.blue),
                            const SizedBox(width: 8),
                            Text(
                              'ТОП користувачів',
                              style: theme.textTheme.titleMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (sortedUsers.isEmpty)
                          const Text('Немає даних для відображення')
                        else
                          Column(
                            children: sortedUsers.take(5).map((entry) {
                              final index = sortedUsers.indexOf(entry) + 1;
                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: CircleAvatar(
                                  backgroundColor: Colors.blue.withOpacity(0.1),
                                  child: Text('$index'),
                                ),
                                title: Text(entry.key),
                                trailing: Text(
                                  '${entry.value} скан.',
                                  style: theme.textTheme.titleMedium,
                                ),
                              );
                            }).toList(),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.today, color: Colors.purple),
                            const SizedBox(width: 8),
                            Text(
                              'Активність по днях',
                              style: theme.textTheme.titleMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (sortedDaily.isEmpty)
                          const Text('Сканування відсутні')
                        else
                          Column(
                            children: sortedDaily.map((entry) {
                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  DateFormat('dd.MM.yyyy').format(entry.key),
                                ),
                                trailing: Text(
                                  '${entry.value} скан.',
                                  style: theme.textTheme.titleMedium,
                                ),
                              );
                            }).toList(),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
  }

  Future<void> _pickStatsDate({required bool isStart}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart
          ? (_statsStartDate ?? now)
          : (_statsEndDate ?? _statsStartDate ?? now),
      firstDate: DateTime(2024),
      lastDate: now,
      locale: const Locale('uk', 'UA'),
    );

    if (picked != null) {
      setState(() {
        if (isStart) {
          _statsStartDate = picked;
        } else {
          _statsEndDate = picked;
        }
      });
      _applyStatsFilters();
    }
  }

  Widget _statCard({
    required ThemeData theme,
    required String title,
    required String value,
    required IconData icon,
    required MaterialColor color,
  }) {
    return SizedBox(
      width: 220,
      child: Card(
        color: color.withOpacity(0.08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: color.shade700,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanpakRecord {
  const _ScanpakRecord({
    required this.number,
    required this.user,
    required this.timestamp,
  });

  final String number;
  final String user;
  final DateTime timestamp;

  static _ScanpakRecord fromJson(Map<String, dynamic> map) {
    final number = map['parcel_number']?.toString() ?? '';
    final user = map['username']?.toString() ?? '';
    final timestampRaw = map['scanned_at']?.toString() ?? '';
    final timestamp = _parseTimestamp(timestampRaw);
    if (number.isEmpty) {
      throw const FormatException('Некоректні дані сканування');
    }
    return _ScanpakRecord(number: number, user: user, timestamp: timestamp);
  }

  static DateTime _parseTimestamp(String raw) {
    final parsed = DateTime.tryParse(raw.trim());
    if (parsed == null) {
      throw const FormatException('Некоректні дані сканування');
    }

    final hasTimezone =
        RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(raw.trim());
    final utcTime = hasTimezone
        ? parsed.toUtc()
        : DateTime.utc(
            parsed.year,
            parsed.month,
            parsed.day,
            parsed.hour,
            parsed.minute,
            parsed.second,
            parsed.millisecond,
            parsed.microsecond,
          );

    return utcTime.toLocal();
  }

  static _ScanpakRecord fromResponse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Некоректна відповідь сервера');
    }
    return fromJson(decoded);
  }

  static List<_ScanpakRecord> decodeList(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(_ScanpakRecord.fromJson)
        .toList();
  }
}
