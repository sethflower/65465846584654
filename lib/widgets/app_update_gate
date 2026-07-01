import 'package:flutter/material.dart';

import '../services/app_update_service.dart';

class AppUpdateGate extends StatefulWidget {
  final Widget child;

  const AppUpdateGate({
    super.key,
    required this.child,
  });

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate> {
  final AppUpdateService _updateService = AppUpdateService();

  bool _checking = true;
  AppUpdateInfo? _updateInfo;

  @override
  void initState() {
    super.initState();
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    try {
      final result = await _updateService.checkForUpdate();

      if (!mounted) return;

      setState(() {
        _updateInfo = result;
        _checking = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _checking = false;
      });
    }
  }

  Future<void> _downloadUpdate() async {
    final info = _updateInfo;
    if (info == null) return;

    try {
      await _updateService.openDownloadUrl(info.downloadUrl);
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось открыть ссылку для загрузки обновления.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return widget.child;
    }

    final info = _updateInfo;

    if (info == null) {
      return widget.child;
    }

    return UpdateRequiredScreen(
      updateInfo: info,
      onDownload: _downloadUpdate,
    );
  }
}

class UpdateRequiredScreen extends StatelessWidget {
  final AppUpdateInfo updateInfo;
  final VoidCallback onDownload;

  const UpdateRequiredScreen({
    super.key,
    required this.updateInfo,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // ✅ Пользователь не сможет выйти назад и обойти обновление
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Container(
            width: double.infinity,
            height: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0F172A),
                  Color(0xFF1E293B),
                  Color(0xFF020617),
                ],
              ),
            ),
            child: Stack(
              children: [
                Align(
                  alignment: const Alignment(0, -0.52),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 86,
                            height: 86,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.16),
                              ),
                            ),
                            child: const Icon(
                              Icons.system_update_alt_rounded,
                              size: 52,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 22),
                          const Text(
                            'Доступно обновление',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 30,
                              height: 1.15,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Версия ${updateInfo.version}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 18,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF93C5FD),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            updateInfo.notes.trim().isEmpty
                                ? 'Планове оновлення додатку. Будь-ласка завантажте нову версію'
                                : updateInfo.notes,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 17,
                              height: 1.45,
                              color: Color(0xFFE2E8F0),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // ✅ Кнопка строго по центру экрана
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: SizedBox(
                        width: double.infinity,
                        height: 64,
                        child: ElevatedButton(
                          onPressed: onDownload,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: const Color(0xFF0F172A),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(22),
                            ),
                          ),
                          child: const Text(
                            'Завантажити оновлення',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                            ),
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
      ),
    );
  }
}
