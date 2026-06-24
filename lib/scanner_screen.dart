import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_barcode_listener/flutter_barcode_listener.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'app_design.dart';
import 'camera_scanner_page.dart';
import 'utils/access_utils.dart';
import 'utils/offline_queue.dart';
import 'utils/tracking_api.dart';

// 🔊 добавили пакет для звука
import 'package:audioplayers/audioplayers.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final TextEditingController _boxController = TextEditingController();
  final TextEditingController _ttnController = TextEditingController();
  final FocusNode _boxFocus = FocusNode();
  final FocusNode _ttnFocus = FocusNode();
  bool _isOnline = true; // 🟢 состояние соединения
  String _status = '';
  String _userName = 'operator';

  int _inFlightSends = 0;

  String _roleLabel = '';
  Color _roleColor = Colors.grey;
  bool _isAdmin = false;

  String _sanitizeNumeric(String value) {
    final digitsOnly = value.replaceAll(RegExp(r'\D'), '');
    return digitsOnly;
  }

  late final Connectivity _connectivity;
  late final Stream<List<ConnectivityResult>> _connectivityStream;

  // 🔊 аудиоплеер — один инстанс на экран
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _loadUserAndRole();

    _connectivity = Connectivity();
    _connectivityStream = _connectivity.onConnectivityChanged;

    // Подписываемся на изменения соединения
    _connectivityStream.listen((List<ConnectivityResult> results) async {
      final online =
          results.isNotEmpty && results.first != ConnectivityResult.none;
      if (mounted) {
        setState(() => _isOnline = online);
      }
      if (online) {
        await OfflineQueue.syncPending(); // 🔁 при возврате сети — синхронизация
      }
    });

    // 🔊 при желании можно задать громкость (0.0–1.0)
    // _audioPlayer.setVolume(1.0);

    _boxFocus.addListener(_onFocusChanged);
    _ttnFocus.addListener(_onFocusChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _boxFocus.requestFocus();
    });
  }

  Future<void> _loadUserAndRole() async {
    final prefs = await SharedPreferences.getInstance();
    final savedName = prefs.getString('user_name') ?? 'operator';
    final roleInfo = await getUserAccessInfo();

    setState(() {
      _userName = savedName;
      _roleLabel = roleInfo['label'];
      _roleColor = roleInfo['color'];
      _isAdmin = roleInfo['isAdmin'] == true;
    });
  }

  @override
  void dispose() {
    _boxController.dispose();
    _ttnController.dispose();
    _boxFocus.removeListener(_onFocusChanged);
    _ttnFocus.removeListener(_onFocusChanged);
    _boxFocus.dispose();
    _ttnFocus.dispose();
    // 🔊 освобождаем плеер
    _audioPlayer.dispose();
    super.dispose();
  }

  // 🔊 заменили системные звуки на проигрывание ассетов
  Future<void> playSuccessSound() async {
    try {
      await _audioPlayer.stop(); // на случай наложений
      await _audioPlayer.play(AssetSource('sounds/success.wav'));
    } catch (_) {
      // fallback: системный щелчок, если ассет не найден
      await SystemSound.play(SystemSoundType.click);
    }
  }

  Future<void> playErrorSound() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('sounds/error.wav'));
    } catch (_) {
      await SystemSound.play(SystemSoundType.alert);
    }
  }

  void _onFocusChanged() {
    if (mounted) {
      if (_boxFocus.hasFocus && _boxController.text.isNotEmpty) {
        _boxController.clear();
      }
      if (_ttnFocus.hasFocus && _ttnController.text.isNotEmpty) {
        _ttnController.clear();
      }
      setState(() {});
    }
  }

  Future<void> _handleScannedCode(String code) async {
    final trimmed = code.trim();
    final sanitized = _sanitizeNumeric(trimmed);

    if (sanitized.isEmpty) return;

    final shouldHandleAsBox =
        _boxController.text.trim().isEmpty || _boxFocus.hasFocus;

    if (shouldHandleAsBox || !_ttnFocus.hasFocus) {
      await _handleBoxSubmitted(sanitized);
    } else {
      await _handleTtnSubmitted(sanitized);
    }
  }

  Future<void> _handleBoxSubmitted(String value) async {
    final trimmed = value.trim();
    final sanitized = _sanitizeNumeric(trimmed);
    if (sanitized.isEmpty) return;

    setState(() {
      _boxController.text = sanitized;
    });

    await playSuccessSound(); // 🔊 сигнал: BoxID принят
    _ttnFocus.requestFocus();
  }

  Future<void> _handleTtnSubmitted(String value) async {
    final trimmed = value.trim();
    final sanitized = _sanitizeNumeric(trimmed);
    if (sanitized.isEmpty) return;

    final sanitizedBox = _sanitizeNumeric(_boxController.text.trim());

     if (sanitizedBox.isEmpty) {
      _boxFocus.requestFocus();
      return;
    }

    _boxController.text = sanitizedBox;
    _ttnController.text = sanitized;
    await _sendRecord();
  }

  Future<void> _sendRecord() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    final userName = prefs.getString('user_name') ?? _userName;

    final boxid = _sanitizeNumeric(_boxController.text.trim());
    final ttn = _sanitizeNumeric(_ttnController.text.trim());

    if (boxid.isEmpty || ttn.isEmpty) return;

    final record = {'user_name': userName, 'boxid': boxid, 'ttn': ttn};

    setState(() {
      _inFlightSends++;
      _status = '⏳ Надсилання...';
    });

    // Отправляем запись в фоне, не блокируя ввод следующей
    _processRecord(record, token);

    _boxController.clear();
    _ttnController.clear();

    Future.delayed(const Duration(milliseconds: 150), () {
      _boxFocus.requestFocus();
    });
  }

  Future<void> _processRecord(
      Map<String, dynamic> record, String? token) async {
    try {
      if (!_isOnline || token == null) throw Exception("Offline");

      print('➡️ TrackingApp: надсилаємо запис ${record['boxid']} / ${record['ttn']}');
      final response = await http.post(
        trackingApiUri('/add_record'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(record),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final note = data['note'] ?? '';

        if (note.isEmpty) {
          await playSuccessSound(); // 🔊 подтверждение успешной записи
          if (mounted) {
            setState(() => _status = '✅ Успішно додано');
          }
        } else {
          await playErrorSound(); // 🔊 дубль = ошибка
          if (mounted) {
            setState(() => _status = '⚠️ Дублікат: $note');
          }
        }
      } else {
        throw Exception("Server error: ${response.statusCode}: ${response.body}");
      }
    } catch (e) {
      print('❌ TrackingApp: не вдалося надіслати запис: $e');
      // 💾 Офлайн-сохранение
      await OfflineQueue.addRecord(record);
      await playErrorSound(); // 🔊 офлайн = ошибка
      if (mounted) {
        setState(() => _status = '📦 Збережено локально (офлайн)');
      }
    } finally {
      await OfflineQueue.syncPending();
      if (mounted) {
        setState(() {
          _inFlightSends = _inFlightSends > 0 ? _inFlightSends - 1 : 0;
        });
      }
    }
  }

  Future<void> _openCameraScanner() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => CameraScannerPage(
          targetLabel: _boxFocus.hasFocus ? 'BoxID' : 'ТТН',
        ),
      ),
    );

    if (!mounted || result == null || result.trim().isEmpty) return;

    await _handleScannedCode(result); // 🔊 await не обязателен, но безопаснее
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isCompact = width < 720;

    return Scaffold(
      body: BarcodeKeyboardListener(
        bufferDuration: const Duration(milliseconds: 200),
        onBarcodeScanned: _handleScannedCode,
        child: SafeArea(
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(
                  horizontal: isCompact ? 14 : 28,
                  vertical: 14,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.navy, AppColors.blue],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.qr_code_scanner, color: Colors.white),
                        const SizedBox(width: 10),
                        Text(
                          'TrackingApp',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        StatusPill(
                          label: _isOnline ? 'Онлайн' : 'Офлайн',
                          icon: _isOnline ? Icons.wifi : Icons.wifi_off,
                          color: _isOnline ? AppColors.emerald : Colors.redAccent,
                        ),
                        StatusPill(label: _roleLabel.isEmpty ? 'Оператор' : _roleLabel, icon: Icons.verified_user_outlined, color: _roleColor),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(isCompact ? 12 : 24, 12, isCompact ? 12 : 24, 0),
                child: SectionCard(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      StatusPill(label: 'Оператор: $_userName', icon: Icons.person, color: AppColors.blue),
                      StatusPill(label: _boxFocus.hasFocus ? 'Сканируется BoxID' : 'Сканируется ТТН', icon: Icons.center_focus_strong, color: _boxFocus.hasFocus ? AppColors.blue : AppColors.amber),
                      Wrap(
                        spacing: 4,
                        children: [
                          IconButton.filledTonal(icon: const Icon(Icons.camera_alt_outlined), tooltip: 'Сканувати камерою', onPressed: _openCameraScanner),
                          IconButton.filledTonal(icon: const Icon(Icons.history), tooltip: 'Переглянути історію', onPressed: () => Navigator.pushNamed(context, '/history')),
                          IconButton.filledTonal(icon: const Icon(Icons.error_outline), tooltip: 'Переглянути помилки', onPressed: () => Navigator.pushNamed(context, '/errors')),
                          if (_isAdmin) IconButton.filledTonal(icon: const Icon(Icons.insights), tooltip: 'Переглянути статистику', onPressed: () => Navigator.pushNamed(context, '/statistics')),
                          IconButton.filledTonal(icon: const Icon(Icons.logout), tooltip: 'Вийти', onPressed: () async {
                            final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Підтвердження виходу'), content: const Text('Ви впевнені, що хочете вийти з акаунту?'), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Скасувати')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Вийти'))]));
                            if (confirm == true) {
                              final prefs = await SharedPreferences.getInstance();
                              for (final key in const {'token', 'access_level', 'user_name', 'user_role'}) { await prefs.remove(key); }
                              if (context.mounted) Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
                            }
                          }),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(isCompact ? 16 : 28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: SectionCard(
                        padding: EdgeInsets.all(isCompact ? 18 : 28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('Сканирование BoxID → ТТН', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, color: AppColors.navy)),
                            const SizedBox(height: 10),
                            Text('Сканируйте два значения подряд. После успешной отправки форма автоматически готова к следующей операции.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.slate)),
                            if (_inFlightSends > 0) ...[const SizedBox(height: 20), LinearProgressIndicator(color: AppColors.emerald), const SizedBox(height: 8), Text('Фонова відправка: $_inFlightSends', textAlign: TextAlign.center)],
                            const SizedBox(height: 24),
                            TextField(controller: _boxController, focusNode: _boxFocus, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800), inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'BoxID', hintText: 'Введіть або відскануйте BoxID', prefixIcon: Icon(Icons.inventory_2_outlined)), onSubmitted: _handleBoxSubmitted),
                            const SizedBox(height: 18),
                            TextField(controller: _ttnController, focusNode: _ttnFocus, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800), inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'ТТН', hintText: 'Введіть або відскануйте ТТН', prefixIcon: Icon(Icons.local_shipping_outlined)), onSubmitted: _handleTtnSubmitted),
                            if (_status.isNotEmpty) ...[const SizedBox(height: 22), StatusPill(label: _status, icon: Icons.info_outline, color: _status.contains('Успішно') ? AppColors.emerald : AppColors.amber)],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }}