import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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
  final TextEditingController _statsUserFilterController =
      TextEditingController();

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
        if (!_tabController.indexIsChanging) setState(() {});
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
    } catch (_) {}
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Немає зв’язку або сервер недоступний. Збережено локально.'),
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
            (r) => r.user.toLowerCase().contains(userFilter.toLowerCase()),
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
          afterStart = time.hour > _startTime!.hour ||
              (time.hour == _startTime!.hour &&
                  time.minute >= _startTime!.minute);
        }

        if (_endTime != null) {
          beforeEnd = time.hour < _endTime!.hour ||
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
          .where((r) =>
              r.timestamp.toLocal().isAfter(start) ||
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

    final topUserEntry =
        userCounts.entries.fold<MapEntry<String, int>?>(null, (previous, element) {
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

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('scanpak_token');
    await prefs.remove('scanpak_user_name');
    await prefs.remove('scanpak_user_role');
    await prefs.remove('last_module');
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/start');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.deepBlue,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          const Positioned.fill(child: _Background()),
          SafeArea(
            child: Column(
              children: [
                _Header(
                  userName: _userName,
                  isOnline: _isOnline,
                  tabController: _tabController,
                  onLogout: _logout,
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildScanTab(),
                      _buildHistoryTab(),
                      _buildStatsTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ───────── Scan tab (акцент на поле) ─────────

  Widget _buildScanTab() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isVerySmall = constraints.maxHeight < 560;
        final hPad = constraints.maxWidth < 380 ? 16.0 : 22.0;
        final cardWidth = math.min(constraints.maxWidth - hPad * 2, 480.0);

        return Center(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 16),
            child: SizedBox(
              width: cardWidth,
              child: Container(
                padding: EdgeInsets.all(isVerySmall ? 18 : 24),
                decoration: BoxDecoration(
                  color: _C.panel,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: _C.deepBlue.withOpacity(0.30),
                      blurRadius: 30,
                      offset: const Offset(0, 16),
                    ),
                    BoxShadow(
                      color: _C.emerald.withOpacity(0.12),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(11),
                            color: _C.emerald.withOpacity(0.14),
                          ),
                          child: const Icon(Icons.person_outline,
                              size: 20, color: _C.emerald),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _userName == null
                                ? 'Сканування'
                                : 'Оператор: $_userName',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: _C.textDark,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: isVerySmall ? 18 : 26),

                    // АКЦЕНТНОЕ ПОЛЕ
                    _ScanField(
                      controller: _numberController,
                      focusNode: _numberFocus,
                      onChanged: _onChanged,
                      onSubmitted: _handleSubmit,
                    ),

                    SizedBox(height: isVerySmall ? 16 : 22),

                    _PrimaryButton(
                      label: 'Зберегти скан',
                      icon: Icons.save_rounded,
                      onTap: () => _handleSubmit(),
                    ),

                    if (_status.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _StatusBox(text: _status),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

      // ───────── History tab ─────────

  Widget _buildHistoryTab() {
    return Column(
      children: [
        _GlassPanel(
          margin: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Row(
            children: [
              Expanded(
                child: _FilterField(
                  controller: _parcelFilterController,
                  label: 'Пошук за номером',
                  width: double.infinity,
                  onChanged: (_) => _applyFilters(),
                ),
              ),
              const SizedBox(width: 8),
              _ChipButton(
                icon: Icons.clear,
                label: 'Скинути',
                ghost: true,
                onTap: _clearFilters,
              ),
              const SizedBox(width: 6),
              _ChipButton(
                icon: Icons.refresh,
                label: 'Оновити',
                ghost: true,
                onTap: _fetchHistory,
              ),
            ],
          ),
        ),
        Expanded(
          child: _isLoadingHistory
              ? const Center(
                  child: CircularProgressIndicator(color: _C.emerald),
                )
              : _filteredRecords.isEmpty
                  ? _EmptyState(
                      icon: Icons.inbox_outlined,
                      text: 'Історія порожня',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                      itemCount: _filteredRecords.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final record = _filteredRecords[index];
                        final localTime = record.timestamp.toLocal();
                        final date =
                            DateFormat('dd.MM.yyyy').format(localTime);
                        final time = DateFormat('HH:mm').format(localTime);

                        return _RecordCard(
                          number: record.number,
                          user: record.user,
                          date: date,
                          time: time,
                        );
                      },
                    ),
        ),
      ],
    );
  }

  // ───────── Stats tab ─────────

  Widget _buildStatsTab() {
    final dateRangeLabel = _statsStartDate == null && _statsEndDate == null
        ? 'Усі дні'
        : '${_statsStartDate == null ? '—' : DateFormat('dd.MM.yyyy').format(_statsStartDate!)} – ${_statsEndDate == null ? '—' : DateFormat('dd.MM.yyyy').format(_statsEndDate!)}';

    final sortedUsers = _userStats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final sortedDaily = _dailyStats.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));

    if (_isLoadingHistory) {
      return const Center(child: CircularProgressIndicator(color: _C.emerald));
    }

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _GlassPanel(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _FilterField(
                  controller: _statsUserFilterController,
                  label: 'Користувач',
                  width: 180,
                  enabled: !_isOperator,
                  onChanged: (_) => _applyStatsFilters(),
                ),
                _ChipButton(
                  icon: Icons.calendar_today,
                  label: _statsStartDate == null
                      ? 'Початок'
                      : DateFormat('dd.MM.yyyy').format(_statsStartDate!),
                  onTap: () => _pickStatsDate(isStart: true),
                ),
                _ChipButton(
                  icon: Icons.event,
                  label: _statsEndDate == null
                      ? 'Кінець'
                      : DateFormat('dd.MM.yyyy').format(_statsEndDate!),
                  onTap: () => _pickStatsDate(isStart: false),
                ),
                _ChipButton(
                  icon: Icons.refresh,
                  label: 'Оновити',
                  ghost: true,
                  onTap: _fetchHistory,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Діапазон: $dateRangeLabel',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Colors.white.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _StatCard(
                title: 'Всього сканів',
                value: _statsRecords.length.toString(),
                icon: Icons.inventory_2,
                color: _C.emerald,
              ),
              _StatCard(
                title: 'Користувачів',
                value: _userStats.length.toString(),
                icon: Icons.people_alt,
                color: _C.cyan,
              ),
              _StatCard(
                title: 'Лідер',
                value:
                    _topUserCount == 0 ? '—' : '$_topUser ($_topUserCount)',
                icon: Icons.emoji_events,
                color: _C.amber,
              ),
              _StatCard(
                title: 'Останній скан',
                value: _latestStatsRecord == null
                    ? '—'
                    : DateFormat('dd.MM • HH:mm')
                        .format(_latestStatsRecord!.timestamp.toLocal()),
                icon: Icons.access_time,
                color: _C.softBlue,
              ),
            ],
          ),
          const SizedBox(height: 14),
          _ListPanel(
            title: 'ТОП користувачів',
            icon: Icons.leaderboard,
            iconColor: _C.emerald,
            child: sortedUsers.isEmpty
                ? const _PanelEmpty('Немає даних для відображення')
                : Column(
                    children: sortedUsers.take(5).map((entry) {
                      final index = sortedUsers.indexOf(entry) + 1;
                      return _RankTile(
                        rank: '$index',
                        title: entry.key,
                        trailing: '${entry.value} скан.',
                      );
                    }).toList(),
                  ),
          ),
          const SizedBox(height: 12),
          _ListPanel(
            title: 'Активність по днях',
            icon: Icons.today,
            iconColor: _C.cyan,
            child: sortedDaily.isEmpty
                ? const _PanelEmpty('Сканування відсутні')
                : Column(
                    children: sortedDaily.map((entry) {
                      return _RankTile(
                        title: DateFormat('dd.MM.yyyy').format(entry.key),
                        trailing: '${entry.value} скан.',
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Palette ─────────────────────────

class _C {
  static const deepBlue = Color(0xFF06122F);
  static const softBlue = Color(0xFF3F8CFF);
  static const cyan = Color(0xFF04C8E8);
  static const emerald = Color(0xFF14C9A6);
  static const mint = Color(0xFF5EF2D0);
  static const amber = Color(0xFFFFB020);
  static const textDark = Color(0xFF0B1530);
  static const textMuted = Color(0xFF60708C);
  static const panel = Color(0xFFFFFFFF);
  static const fieldBg = Color(0xFFF1F6F4);
}

// ───────────────────────── Header + Tabs ─────────────────────────

class _Header extends StatelessWidget {
  final String? userName;
  final bool isOnline;
  final TabController tabController;
  final VoidCallback onLogout;

  const _Header({
    required this.userName,
    required this.isOnline,
    required this.tabController,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final color = isOnline ? _C.emerald : Colors.redAccent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [_C.mint, _C.emerald],
                  ),
                ),
                child: const Icon(Icons.inventory_2_rounded,
                    color: Colors.white, size: 22),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'СканПак',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    color: Colors.white,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: color.withOpacity(0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(isOnline ? Icons.wifi : Icons.wifi_off,
                        size: 14, color: color),
                    const SizedBox(width: 6),
                    Text(
                      isOnline ? 'Онлайн' : 'Офлайн',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: Colors.redAccent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: onLogout,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: Colors.redAccent.withOpacity(0.35)),
                    ),
                    child: const Icon(Icons.logout_rounded,
                        size: 20, color: Colors.redAccent),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withOpacity(0.10)),
            ),
            padding: const EdgeInsets.all(4),
            child: TabBar(
              controller: tabController,
              indicator: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_C.mint, _C.emerald],
                ),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              labelStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              unselectedLabelStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              tabs: const [
                Tab(text: 'Сканування'),
                Tab(text: 'Історія'),
                Tab(text: 'Статистика'),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

// ───────────────────────── Scan field (акцент) ─────────────────────────

class _ScanField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  const _ScanField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: focusNode,
      builder: (context, _) {
        final active = focusNode.hasFocus;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    gradient: active
                        ? const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [_C.mint, _C.emerald],
                          )
                        : null,
                    color: active ? null : _C.emerald.withOpacity(0.14),
                  ),
                  child: Icon(Icons.qr_code_scanner_rounded,
                      size: 21,
                      color: active ? Colors.white : _C.emerald),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Номер посилки',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: _C.textDark,
                  ),
                ),
                const Spacer(),
                if (active)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _C.emerald.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: const Text(
                      'Активне',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: _C.emerald,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: _C.fieldBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: active ? _C.emerald : Colors.transparent,
                  width: 2,
                ),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: _C.emerald.withOpacity(0.20),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : null,
              ),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                textAlign: TextAlign.center,
                cursorColor: _C.emerald,
                textInputAction: TextInputAction.done,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                  color: _C.textDark,
                ),
                decoration: const InputDecoration(
                  hintText: 'Відскануйте BoxID',
                  hintStyle: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: _C.textMuted,
                  ),
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 18),
                ),
                onChanged: onChanged,
                onSubmitted: onSubmitted,
              ),
            ),
          ],
        );
      },
    );
  }
}

// ───────────────────────── Primary button ─────────────────────────

class _PrimaryButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_C.mint, _C.emerald],
            ),
            boxShadow: [
              BoxShadow(
                color: _C.emerald.withOpacity(0.40),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Status box ─────────────────────────

class _StatusBox extends StatelessWidget {
  final String text;
  const _StatusBox({required this.text});

  @override
  Widget build(BuildContext context) {
    final bool success = text.contains('Збережено для');
    final bool waiting = text.contains('Відправляємо');
    final Color color = success
        ? _C.emerald
        : waiting
            ? _C.softBlue
            : _C.amber;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            success
                ? Icons.check_circle_outline
                : waiting
                    ? Icons.hourglass_top_rounded
                    : Icons.info_outline,
            size: 20,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.3,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Glass panel ─────────────────────────

class _GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsets? margin;
  const _GlassPanel({required this.child, this.margin});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: child,
    );
  }
}

// ───────────────────────── Filter field ─────────────────────────

class _FilterField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final double width;
  final ValueChanged<String> onChanged;

  const _FilterField({
    required this.controller,
    required this.label,
    required this.onChanged,
    this.enabled = true,
    this.width = 150,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        enabled: enabled,
        onChanged: onChanged,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        cursorColor: _C.mint,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            color: Colors.white.withOpacity(0.65),
            fontSize: 13,
          ),
          isDense: true,
          filled: true,
          fillColor: Colors.white.withOpacity(0.07),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _C.mint, width: 1.5),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Chip button ─────────────────────────

class _ChipButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool ghost;

  const _ChipButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.ghost = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ghost
          ? Colors.transparent
          : Colors.white.withOpacity(0.10),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withOpacity(ghost ? 0.18 : 0.12),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: _C.mint),
              const SizedBox(width: 7),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Record card ─────────────────────────

class _RecordCard extends StatelessWidget {
  final String number;
  final String user;
  final String date;
  final String time;

  const _RecordCard({
    required this.number,
    required this.user,
    required this.date,
    required this.time,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _C.panel,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _C.deepBlue.withOpacity(0.18),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Номер BoxID: всегда полный, в одну строку ──
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: _C.emerald.withOpacity(0.12),
                ),
                child: const Icon(Icons.inventory_2,
                    size: 19, color: _C.emerald),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    number,
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                      color: _C.textDark,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // ── Дата, время и пользователь ──
          Row(
            children: [
              const Icon(Icons.schedule, size: 15, color: _C.textMuted),
              const SizedBox(width: 6),
              Text(
                '$date • $time',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _C.textMuted,
                ),
              ),
              const SizedBox(width: 14),
              const Icon(Icons.person_outline, size: 15, color: _C.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  user,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _C.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Stat card ─────────────────────────

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 165,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _C.panel,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: _C.deepBlue.withOpacity(0.18),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: color.withOpacity(0.14),
                  ),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _C.textMuted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── List panel ─────────────────────────

class _ListPanel extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;
  final Widget child;

  const _ListPanel({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _C.panel,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: _C.deepBlue.withOpacity(0.18),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: _C.textDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _RankTile extends StatelessWidget {
  final String? rank;
  final String title;
  final String trailing;

  const _RankTile({
    this.rank,
    required this.title,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          if (rank != null) ...[
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _C.emerald.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Text(
                rank!,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: _C.emerald,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _C.textDark,
              ),
            ),
          ),
          Text(
            trailing,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: _C.textDark,
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelEmpty extends StatelessWidget {
  final String text;
  const _PanelEmpty(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13.5,
          color: _C.textMuted,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;

  const _EmptyState({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: Colors.white.withOpacity(0.4)),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.white.withOpacity(0.65),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Background ─────────────────────────

class _Background extends StatelessWidget {
  const _Background();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: const [
                  Color(0xFF06122F),
                  Color(0xFF073D52),
                  Color(0xFF067A78),
                  Color(0xFF04A6CE),
                ],
                stops: const [0.0, 0.4, 0.75, 1.0],
              ),
            ),
          ),
        ),
        const Positioned.fill(
          child: CustomPaint(painter: _MeshPainter()),
        ),
        Positioned(
          left: -130,
          top: -120,
          child: _Glow(size: 320, color: _C.mint.withOpacity(0.30)),
        ),
        Positioned(
          right: -150,
          bottom: -130,
          child: _Glow(size: 400, color: _C.cyan.withOpacity(0.26)),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _C.deepBlue.withOpacity(0.35),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.4],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Glow extends StatelessWidget {
  final double size;
  final Color color;

  const _Glow({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withOpacity(0)],
          ),
        ),
      ),
    );
  }
}

class _MeshPainter extends CustomPainter {
  const _MeshPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withOpacity(0.04);

    const step = 46.0;

    for (double x = -size.height; x < size.width; x += step * 2) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        linePaint,
      );
    }

    final dotPaint = Paint()..style = PaintingStyle.fill;
    for (double x = 24; x < size.width; x += step) {
      for (double y = 24; y < size.height; y += step) {
        final fade = 1 - (y / size.height);
        dotPaint.color = Colors.white.withOpacity(0.03 * fade);
        canvas.drawCircle(Offset(x, y), 1.1, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ───────────────────────── Record model ─────────────────────────

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