import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_barcode_listener/flutter_barcode_listener.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:audioplayers/audioplayers.dart';

import 'utils/access_utils.dart';
import 'utils/offline_queue.dart';
import 'utils/tracking_api.dart';

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
  bool _isOnline = true;
  String _status = '';
  String _userName = 'operator';

  int _inFlightSends = 0;
  bool _isAdmin = false;

  late final Connectivity _connectivity;
  late final Stream<List<ConnectivityResult>> _connectivityStream;
  final AudioPlayer _audioPlayer = AudioPlayer();

  String _sanitizeNumeric(String value) => value.replaceAll(RegExp(r'\D'), '');

  @override
  void initState() {
    super.initState();
    _loadUserAndRole();

    _connectivity = Connectivity();
    _connectivityStream = _connectivity.onConnectivityChanged;

    _connectivityStream.listen((List<ConnectivityResult> results) async {
      final online =
          results.isNotEmpty && results.first != ConnectivityResult.none;
      if (mounted) {
        setState(() => _isOnline = online);
      }
      if (online) {
        await OfflineQueue.syncPending();
      }
    });

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
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> playSuccessSound() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('sounds/success.wav'));
    } catch (_) {
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
    final sanitized = _sanitizeNumeric(code.trim());
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
    final sanitized = _sanitizeNumeric(value.trim());
    if (sanitized.isEmpty) return;

    setState(() {
      _boxController.text = sanitized;
    });

    await playSuccessSound();
    _ttnFocus.requestFocus();
  }

  Future<void> _handleTtnSubmitted(String value) async {
    final sanitized = _sanitizeNumeric(value.trim());
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
          await playSuccessSound();
          if (mounted) {
            setState(() => _status = '✅ Успішно додано');
          }
        } else {
          await playErrorSound();
          if (mounted) {
            setState(() => _status = '⚠️ Дублікат: $note');
          }
        }
      } else {
        throw Exception(
            "Server error: ${response.statusCode}: ${response.body}");
      }
    } catch (e) {
      await OfflineQueue.addRecord(record);
      await playErrorSound();
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

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Підтвердження виходу',
          style: TextStyle(color: _C.textDark, fontWeight: FontWeight.w800),
        ),
        content: const Text('Ви впевнені, що хочете вийти з акаунту?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Скасувати'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _C.blue,
              foregroundColor: Colors.white,
            ),
            child: const Text('Вийти'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      final prefs = await SharedPreferences.getInstance();
      for (final key in const {
        'token',
        'access_level',
        'user_name',
        'user_role'
        'last_module',
      }) {
        await prefs.remove(key);
      }
      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(context, '/start', (route) => false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.deepBlue,
      resizeToAvoidBottomInset: false,
      body: BarcodeKeyboardListener(
        bufferDuration: const Duration(milliseconds: 200),
        onBarcodeScanned: _handleScannedCode,
        child: Stack(
          children: [
            const Positioned.fill(child: _Background()),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final h = constraints.maxHeight;
                  final isVerySmall = h < 640;
                  final isNarrow = w < 380;
                  final hPad = isNarrow ? 14.0 : 22.0;
                  final contentWidth = math.min(w - hPad * 2, 520.0);

                  return Padding(
                    padding: EdgeInsets.fromLTRB(hPad, 8, hPad, 10),
                    child: Center(
                      child: SizedBox(
                        width: contentWidth,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.start,
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            _TopBar(
                              userName: _userName,
                              isOnline: _isOnline,
                              isAdmin: _isAdmin,
                              onHistory: () =>
                                  Navigator.pushNamed(context, '/history'),
                              onErrors: () =>
                                  Navigator.pushNamed(context, '/errors'),
                              onLogout: _logout,
                            ),
                            SizedBox(height: isVerySmall ? 14 : 22),
                            Expanded(
                              child: SingleChildScrollView(
                                physics: const BouncingScrollPhysics(),
                                child: _ScanCard(
                                  compact: isVerySmall,
                                  boxController: _boxController,
                                  ttnController: _ttnController,
                                  boxFocus: _boxFocus,
                                  ttnFocus: _ttnFocus,
                                  inFlightSends: _inFlightSends,
                                  status: _status,
                                  onBoxSubmitted: _handleBoxSubmitted,
                                  onTtnSubmitted: _handleTtnSubmitted,
                                ),
                              ),
                            ),
                            const _Footer(),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Palette ─────────────────────────

class _C {
  static const deepBlue = Color(0xFF07153A);
  static const blue = Color(0xFF075BFF);
  static const softBlue = Color(0xFF3F8CFF);
  static const cyan = Color(0xFF04C8E8);
  static const emerald = Color(0xFF14C9A6);
  static const mint = Color(0xFF5EF2D0);
  static const amber = Color(0xFFFFB020);
  static const textDark = Color(0xFF0B1530);
  static const textMuted = Color(0xFF60708C);
  static const panel = Color(0xFFFFFFFF);
  static const fieldBg = Color(0xFFF2F5FB);
}

// ───────────────────────── Top bar ─────────────────────────

class _TopBar extends StatelessWidget {
  final String userName;
  final bool isOnline;
  final bool isAdmin;
  final VoidCallback onHistory;
  final VoidCallback onErrors;
  final VoidCallback onLogout;

  const _TopBar({
    required this.userName,
    required this.isOnline,
    required this.isAdmin,
    required this.onHistory,
    required this.onErrors,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
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
                  colors: [_C.softBlue, _C.blue],
                ),
              ),
              child: const Icon(Icons.qr_code_scanner_rounded,
                  color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'BoxID-ТТН',
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
            _StatusDot(isOnline: isOnline),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.12)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.person_outline,
                        size: 18, color: Colors.white.withOpacity(0.85)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _IconBtn(icon: Icons.history_rounded, onTap: onHistory),
            const SizedBox(width: 6),
            _IconBtn(icon: Icons.error_outline_rounded, onTap: onErrors),
            const SizedBox(width: 6),
            _IconBtn(
              icon: Icons.logout_rounded,
              onTap: onLogout,
              danger: true,
            ),
          ],
        ),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool isOnline;
  const _StatusDot({required this.isOnline});

  @override
  Widget build(BuildContext context) {
    final color = isOnline ? _C.emerald : Colors.redAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isOnline ? Icons.wifi : Icons.wifi_off, size: 14, color: color),
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
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  const _IconBtn({
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? Colors.redAccent : Colors.white;
    return Material(
      color: danger
          ? Colors.redAccent.withOpacity(0.15)
          : Colors.white.withOpacity(0.08),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: danger
                  ? Colors.redAccent.withOpacity(0.35)
                  : Colors.white.withOpacity(0.12),
            ),
          ),
          child: Icon(icon, size: 20, color: color.withOpacity(0.9)),
        ),
      ),
    );
  }
}

// ───────────────────────── Scan card ─────────────────────────

class _ScanCard extends StatelessWidget {
  final bool compact;
  final TextEditingController boxController;
  final TextEditingController ttnController;
  final FocusNode boxFocus;
  final FocusNode ttnFocus;
  final int inFlightSends;
  final String status;
  final ValueChanged<String> onBoxSubmitted;
  final ValueChanged<String> onTtnSubmitted;

  const _ScanCard({
    required this.compact,
    required this.boxController,
    required this.ttnController,
    required this.boxFocus,
    required this.ttnFocus,
    required this.inFlightSends,
    required this.status,
    required this.onBoxSubmitted,
    required this.onTtnSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final boxActive = boxFocus.hasFocus;

    return Container(
      padding: EdgeInsets.all(compact ? 18 : 24),
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
            color: _C.blue.withOpacity(0.12),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ScanField(
            controller: boxController,
            focusNode: boxFocus,
            label: 'BoxID',
            hint: 'Відскануйте BoxID',
            icon: Icons.inventory_2_outlined,
            accent: _C.blue,
            onSubmitted: onBoxSubmitted,
          ),

          SizedBox(height: compact ? 14 : 18),

          _ScanField(
            controller: ttnController,
            focusNode: ttnFocus,
            label: 'ТТН',
            hint: 'Відскануйте ТТН',
            icon: Icons.local_shipping_outlined,
            accent: _C.emerald,
            onSubmitted: onTtnSubmitted,
          ),

          if (inFlightSends > 0) ...[
            SizedBox(height: compact ? 14 : 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: const LinearProgressIndicator(
                color: _C.emerald,
                backgroundColor: _C.fieldBg,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Фонова відправка: $inFlightSends',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _C.textMuted,
              ),
            ),
          ],

          if (status.isNotEmpty) ...[
            SizedBox(height: compact ? 12 : 16),
            _StatusBox(text: status),
          ],
        ],
      ),
    );
  }
}

// ───────────────────────── Scan field ─────────────────────────

class _ScanField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final String hint;
  final IconData icon;
  final Color accent;
  final ValueChanged<String> onSubmitted;

  const _ScanField({
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.hint,
    required this.icon,
    required this.accent,
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
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: accent.withOpacity(active ? 1 : 0.14),
                    gradient: active
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [accent.withOpacity(0.85), accent],
                          )
                        : null,
                  ),
                  child: Icon(
                    icon,
                    size: 19,
                    color: active ? Colors.white : accent,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: _C.textDark,
                  ),
                ),
                const Spacer(),
                if (active)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      'Активне',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: accent,
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
                  color: active ? accent : Colors.transparent,
                  width: 2,
                ),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: accent.withOpacity(0.20),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : null,
              ),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textAlign: TextAlign.center,
                cursorColor: accent,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                  color: _C.textDark,
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: _C.textMuted,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 18,
                  ),
                ),
                onSubmitted: onSubmitted,
              ),
            ),
          ],
        );
      },
    );
  }
}

// ───────────────────────── Status box ─────────────────────────

class _StatusBox extends StatelessWidget {
  final String text;
  const _StatusBox({required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }
    final bool success = text.contains('Успішно');
    final bool waiting = text.contains('Надсилання');
    final Color color = success
        ? _C.emerald
        : waiting
            ? _C.blue
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
                fontSize: 14,
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

// ───────────────────────── Footer ─────────────────────────

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'by Dimon VR · DC Link',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          fontStyle: FontStyle.italic,
          letterSpacing: 0.3,
          color: Colors.white.withOpacity(0.4),
        ),
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
                  Color(0xFF072356),
                  Color(0xFF064AC2),
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
          child: _Glow(size: 320, color: _C.softBlue.withOpacity(0.32)),
        ),
        Positioned(
          right: -150,
          bottom: -130,
          child: _Glow(size: 400, color: _C.mint.withOpacity(0.26)),
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