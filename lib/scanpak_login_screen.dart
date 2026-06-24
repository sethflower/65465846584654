import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_design.dart';

import 'scanpak_admin_panel_screen.dart';
import 'utils/scanpak_auth.dart';
import 'utils/scanpak_user_management.dart';

class ScanpakLoginScreen extends StatefulWidget {
  const ScanpakLoginScreen({super.key});

  @override
  State<ScanpakLoginScreen> createState() => _ScanpakLoginScreenState();
}

class _ScanpakLoginScreenState extends State<ScanpakLoginScreen> {
  final TextEditingController _loginSurnameController = TextEditingController();
  final TextEditingController _loginPasswordController =
      TextEditingController();
  final TextEditingController _registerSurnameController =
      TextEditingController();
  final TextEditingController _registerPasswordController =
      TextEditingController();
  final TextEditingController _registerConfirmController =
      TextEditingController();

  bool _isRegistrationMode = false;
  bool _isLoggingIn = false;
  bool _isRegistering = false;
  String? _loginError;
  String? _registerMessage;
  bool _registerSuccess = false;

  Future<void> _handleLogin() async {
    FocusScope.of(context).unfocus();

    final surname = _loginSurnameController.text.trim();
    final password = _loginPasswordController.text.trim();

    if (surname.isEmpty || password.isEmpty) {
      setState(() => _loginError = 'Введіть прізвище та пароль');
      return;
    }

    setState(() {
      _loginError = null;
      _isLoggingIn = true;
    });

    try {
      final response = await http.post(
        scanpakApiUri('/login'),
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'surname': surname, 'password': password}),
      );

      if (response.statusCode != 200) {
        setState(() => _loginError = _extractServerMessage(response));
        return;
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        setState(() => _loginError = 'Неправильна відповідь сервера');
        return;
      }

      final token = data['token']?.toString() ?? '';
      if (token.isEmpty) {
        setState(() => _loginError = 'Сервер не повернув коректний токен');
        return;
      }

      final resolvedSurname = data['surname']?.toString() ?? surname;
      final rawRole = data['role']?.toString();
      final role = rawRole == null ? null : parseScanpakUserRole(rawRole);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('scanpak_token', token);
      await prefs.setString('scanpak_user_name', resolvedSurname);
      if (role != null) {
        await prefs.setString('scanpak_user_role', role.name);
      }

      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/scanpak/home');
    } on http.ClientException {
      setState(
        () =>
            _loginError = 'Не вдалося зʼєднатися з сервером. Повторіть спробу',
      );
    } on FormatException {
      setState(() => _loginError = 'Неправильна відповідь сервера');
    } catch (e) {
      setState(
        () => _loginError = 'DEBUG SCANPAK LOGIN ERROR: ${e.runtimeType}: $e',
      );
    } finally {
      if (mounted) {
        setState(() => _isLoggingIn = false);
      }
    }
  }

  Future<void> _openAdminPanel() async {
    final controller = TextEditingController();
    final password = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Вхід до панелі адміністратора СканПак'),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Пароль адміністратора',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Скасувати'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Увійти'),
            ),
          ],
        );
      },
    );

    final trimmedPassword = password?.trim() ?? '';
    if (trimmedPassword.isEmpty) {
      if (password != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Введіть пароль адміністратора')),
        );
      }
      return;
    }

    try {
      final response = await http.post(
        scanpakApiUri('/admin_login'),
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'password': trimmedPassword}),
      );

      if (response.statusCode != 200) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_extractServerMessage(response))),
        );
        return;
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Некоректна відповідь сервера')),
        );
        return;
      }

      final token = data['token']?.toString() ?? '';
      if (token.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сервер не повернув токен доступу')),
        );
        return;
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ScanpakAdminPanelScreen(adminToken: token),
        ),
      );
    } on http.ClientException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не вдалося зʼєднатися з сервером')),
      );
    } on FormatException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Некоректна відповідь сервера')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сталася помилка під час входу')),
      );
    }
  }

  Future<void> _handleRegistration() async {
    FocusScope.of(context).unfocus();

    final surname = _registerSurnameController.text.trim();
    final password = _registerPasswordController.text.trim();
    final confirm = _registerConfirmController.text.trim();

    if (surname.isEmpty || password.isEmpty || confirm.isEmpty) {
      setState(() {
        _registerMessage = 'Заповніть усі поля';
        _registerSuccess = false;
      });
      return;
    }

    if (password.length < 6) {
      setState(() {
        _registerMessage = 'Пароль має містити щонайменше 6 символів';
        _registerSuccess = false;
      });
      return;
    }

    if (password != confirm) {
      setState(() {
        _registerMessage = 'Паролі не співпадають';
        _registerSuccess = false;
      });
      return;
    }

    setState(() {
      _isRegistering = true;
      _registerMessage = null;
    });

    try {
      await ScanpakAuthApi.register(surname, password);
      if (!mounted) return;
      setState(() {
        _registerSuccess = true;
        _registerMessage =
            'Заявку на реєстрацію відправлено. Дочекайтесь підтвердження адміністратора.';
        _registerSurnameController.clear();
        _registerPasswordController.clear();
        _registerConfirmController.clear();
      });
    } on ScanpakAuthException catch (error) {
      setState(() {
        _registerSuccess = false;
        _registerMessage = error.message;
      });
    } catch (_) {
      setState(() {
        _registerSuccess = false;
        _registerMessage = 'Не вдалося відправити заявку. Спробуйте пізніше.';
      });
    } finally {
      if (mounted) {
        setState(() => _isRegistering = false);
      }
    }
  }

  String _extractServerMessage(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final detail = body['detail'];
        if (detail is String && detail.isNotEmpty) {
          return detail;
        }
        final message = body['message'];
        if (message is String && message.isNotEmpty) {
          return message;
        }
      }
    } catch (_) {
      // ignore parsing errors
    }
    return 'Помилка (${response.statusCode})';
  }

  @override
  void dispose() {
    _loginSurnameController.dispose();
    _loginPasswordController.dispose();
    _registerSurnameController.dispose();
    _registerPasswordController.dispose();
    _registerConfirmController.dispose();
    super.dispose();
  }

  Widget _buildLoginForm() {
    return Column(
      key: const ValueKey('login_form'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _loginSurnameController,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Прізвище',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _loginPasswordController,
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _handleLogin(),
          decoration: const InputDecoration(
            labelText: 'Пароль',
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        const SizedBox(height: 12),
        if (_loginError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _loginError!,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isLoggingIn ? null : _handleLogin,
            icon: _isLoggingIn
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: Text(_isLoggingIn ? 'Зачекайте...' : 'Увійти'),
          ),
        ),
      ],
    );
  }

  Widget _buildRegistrationForm() {
    return Column(
      key: const ValueKey('registration_form'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _registerSurnameController,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Прізвище',
            prefixIcon: Icon(Icons.person_add_alt_1),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _registerPasswordController,
          obscureText: true,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Пароль',
            prefixIcon: Icon(Icons.lock),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _registerConfirmController,
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _handleRegistration(),
          decoration: const InputDecoration(
            labelText: 'Підтвердження пароля',
            prefixIcon: Icon(Icons.lock_reset),
          ),
        ),
        const SizedBox(height: 12),
        if (_registerMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _registerMessage!,
              style: TextStyle(
                color: _registerSuccess ? Colors.green : Colors.redAccent,
              ),
            ),
          ),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isRegistering ? null : _handleRegistration,
            icon: _isRegistering
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.person_add),
            label: Text(_isRegistering ? 'Надсилання...' : 'Надіслати заявку'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isCompact = width < 760;

    return Scaffold(
      body: ResponsiveShell(
        maxWidth: 980,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.spaceBetween,
              children: [
                OutlinedButton.icon(onPressed: () => Navigator.pushReplacementNamed(context, '/'), style: OutlinedButton.styleFrom(foregroundColor: Colors.white), icon: const Icon(Icons.arrow_back), label: const Text('Назад')),
                FilledButton.tonalIcon(onPressed: _openAdminPanel, icon: const Icon(Icons.admin_panel_settings_outlined), label: const Text('Адмін панель')),
              ],
            ),
            const SizedBox(height: 18),
            GlassPanel(
              padding: EdgeInsets.all(isCompact ? 20 : 32),
              child: Wrap(
                spacing: 28,
                runSpacing: 24,
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: isCompact ? double.infinity : 330,
                    child: Column(
                      crossAxisAlignment: isCompact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                      children: [
                        Image.asset('assets/images/logo.png', width: isCompact ? 92 : 128, height: isCompact ? 92 : 128, errorBuilder: (_, __, ___) => const Icon(Icons.qr_code_2, size: 84, color: AppColors.blue)),
                        const SizedBox(height: 18),
                        Text('СканПак', textAlign: isCompact ? TextAlign.center : TextAlign.left, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, color: AppColors.navy)),
                        const SizedBox(height: 10),
                        Text('Корпоративный вход для учета посылок', textAlign: isCompact ? TextAlign.center : TextAlign.left, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppColors.slate, height: 1.45)),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: isCompact ? double.infinity : 470,
                    child: SectionCard(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SegmentedButton<bool>(
                            segments: const [ButtonSegment(value: false, label: Text('Вхід'), icon: Icon(Icons.login)), ButtonSegment(value: true, label: Text('Реєстрація'), icon: Icon(Icons.person_add_alt_1))],
                            selected: {_isRegistrationMode},
                            onSelectionChanged: (selection) { setState(() { _isRegistrationMode = selection.first; _loginError = null; _registerMessage = null; }); },
                          ),
                          const SizedBox(height: 24),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: SizeTransition(sizeFactor: animation, child: child)),
                            child: _isRegistrationMode ? _buildRegistrationForm() : _buildLoginForm(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Center(child: Text('by Dimon VR', style: TextStyle(color: Colors.white70, fontStyle: FontStyle.italic))),
          ],
        ),
      ),
    );
  }
}