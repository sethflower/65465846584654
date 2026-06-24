import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'admin_panel_screen.dart';
import 'utils/user_management.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _loginSurnameController = TextEditingController();
  final TextEditingController _loginPasswordController = TextEditingController();
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
        apiUri('/login'),
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'surname': surname,
          'password': password,
        }),
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

      final accessLevelRaw = data['access_level'];
      int? accessLevel;
      if (accessLevelRaw is int) {
        accessLevel = accessLevelRaw;
      } else if (accessLevelRaw is num) {
        accessLevel = accessLevelRaw.toInt();
      }

      final roleName = data['role']?.toString();
      final role = parseUserRole(roleName);
      final resolvedSurname = data['surname']?.toString() ?? surname;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', token);
      if (accessLevel != null) {
        await prefs.setInt('access_level', accessLevel);
      }
      await prefs.setString('user_name', resolvedSurname);
      await prefs.setString('user_role', role.name);
      await prefs.setString('last_module', 'tracking');

      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/scanner');
    } on http.ClientException {
      setState(() =>
          _loginError = 'Не вдалося зʼєднатися з сервером. Повторіть спробу');
    } on FormatException {
      setState(() => _loginError = 'Неправильна відповідь сервера');
    } catch (e) {
      setState(() => _loginError = 'DEBUG LOGIN ERROR: ${e.runtimeType}: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoggingIn = false);
      }
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
      await UserApi.registerUser(surname, password);
      if (!mounted) return;
      setState(() {
        _registerSuccess = true;
        _registerMessage =
            'Заявку на реєстрацію відправлено. Дочекайтесь підтвердження адміністратора.';
        _registerSurnameController.clear();
        _registerPasswordController.clear();
        _registerConfirmController.clear();
      });
    } on ApiException catch (error) {
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

  Future<void> _openAdminPanel() async {
    final controller = TextEditingController();
    final password = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            'Вхід до панелі адміністратора',
            style: TextStyle(
              color: _C.textDark,
              fontWeight: FontWeight.w800,
              fontSize: 17,
            ),
          ),
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
              style: ElevatedButton.styleFrom(
                backgroundColor: _C.blue,
                foregroundColor: Colors.white,
              ),
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
        apiUri('/admin_login'),
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
          builder: (_) => AdminPanelScreen(adminToken: token),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.deepBlue,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          const Positioned.fill(child: _Background()),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final h = constraints.maxHeight;

                final isVerySmall = h < 640;
                final isSmall = h < 740;
                final isNarrow = w < 380;

                final hPad = isNarrow ? 16.0 : 24.0;
                final contentWidth = math.min(w - hPad * 2, 440.0);

                return Padding(
                  padding: EdgeInsets.fromLTRB(hPad, 8, hPad, 12),
                  child: Center(
                    child: SizedBox(
                      width: contentWidth,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.max,
                        children: [
                          _TopBar(
                            onBack: () =>
                                Navigator.pushReplacementNamed(context, '/'),
                            onAdmin: _openAdminPanel,
                          ),

                          SizedBox(height: isVerySmall ? 14 : 24),

                          _Brand(compact: isVerySmall),

                          SizedBox(height: isVerySmall ? 16 : 26),

                          Flexible(
                            child: _AuthCard(
                              isRegistrationMode: _isRegistrationMode,
                              compact: isVerySmall || isSmall,
                              onModeChanged: (value) {
                                setState(() {
                                  _isRegistrationMode = value;
                                  _loginError = null;
                                  _registerMessage = null;
                                });
                              },
                              child: _isRegistrationMode
                                  ? _buildRegistrationForm(isVerySmall)
                                  : _buildLoginForm(isVerySmall),
                            ),
                          ),

                          SizedBox(height: isVerySmall ? 8 : 14),

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
    );
  }

  Widget _buildLoginForm(bool compact) {
    final gap = compact ? 12.0 : 16.0;
    return Column(
      key: const ValueKey('login_form'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Field(
          controller: _loginSurnameController,
          label: 'Прізвище',
          icon: Icons.person_outline,
          textInputAction: TextInputAction.next,
        ),
        SizedBox(height: gap),
        _Field(
          controller: _loginPasswordController,
          label: 'Пароль',
          icon: Icons.lock_outline,
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _handleLogin(),
        ),
        if (_loginError != null) ...[
          const SizedBox(height: 12),
          _MessageBox(text: _loginError!, isError: true),
        ],
        SizedBox(height: gap),
        _PrimaryButton(
          label: _isLoggingIn ? 'Зачекайте...' : 'Увійти',
          icon: Icons.login_rounded,
          loading: _isLoggingIn,
          accent: _C.blue,
          soft: _C.softBlue,
          onTap: _isLoggingIn ? null : _handleLogin,
        ),
      ],
    );
  }

  Widget _buildRegistrationForm(bool compact) {
    final gap = compact ? 12.0 : 16.0;
    return Column(
      key: const ValueKey('registration_form'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Field(
          controller: _registerSurnameController,
          label: 'Прізвище',
          icon: Icons.person_add_alt_1,
          textInputAction: TextInputAction.next,
        ),
        SizedBox(height: gap),
        _Field(
          controller: _registerPasswordController,
          label: 'Пароль',
          icon: Icons.lock,
          obscureText: true,
          textInputAction: TextInputAction.next,
        ),
        SizedBox(height: gap),
        _Field(
          controller: _registerConfirmController,
          label: 'Підтвердження пароля',
          icon: Icons.lock_reset,
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _handleRegistration(),
        ),
        if (_registerMessage != null) ...[
          const SizedBox(height: 12),
          _MessageBox(text: _registerMessage!, isError: !_registerSuccess),
        ],
        SizedBox(height: gap),
        _PrimaryButton(
          label: _isRegistering ? 'Надсилання...' : 'Надіслати заявку',
          icon: Icons.person_add_rounded,
          loading: _isRegistering,
          accent: _C.emerald,
          soft: _C.mint,
          onTap: _isRegistering ? null : _handleRegistration,
        ),
      ],
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
  static const textDark = Color(0xFF0B1530);
  static const textMuted = Color(0xFF60708C);
  static const panel = Color(0xFFFFFFFF);
  static const fieldBg = Color(0xFFF2F5FB);
}

// ───────────────────────── Top bar ─────────────────────────

class _TopBar extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onAdmin;

  const _TopBar({required this.onBack, required this.onAdmin});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _GhostButton(
          icon: Icons.arrow_back_rounded,
          label: 'Назад',
          onTap: onBack,
        ),
        const Spacer(),
        _GhostButton(
          icon: Icons.admin_panel_settings_outlined,
          label: 'Адмін',
          onTap: onAdmin,
        ),
      ],
    );
  }
}

class _GhostButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _GhostButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(0.08),
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(99),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: Colors.white.withOpacity(0.85)),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withOpacity(0.85),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Brand ─────────────────────────

class _Brand extends StatelessWidget {
  final bool compact;
  const _Brand({required this.compact});

  @override
  Widget build(BuildContext context) {
    final size = compact ? 60.0 : 72.0;
    return Column(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_C.softBlue, _C.blue],
            ),
            boxShadow: [
              BoxShadow(
                color: _C.blue.withOpacity(0.45),
                blurRadius: 26,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Icon(
            Icons.qr_code_scanner_rounded,
            color: Colors.white,
            size: compact ? 30 : 36,
          ),
        ),
        SizedBox(height: compact ? 14 : 18),
        Text(
          'BoxID-ТТН',
          style: TextStyle(
            fontSize: compact ? 24 : 28,
            height: 1.0,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'МАРКУВАННЯ ПОСИЛОК НП',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            height: 1.0,
            fontWeight: FontWeight.w600,
            letterSpacing: 2.6,
            color: Colors.white.withOpacity(0.55),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── Auth card ─────────────────────────

class _AuthCard extends StatelessWidget {
  final bool isRegistrationMode;
  final bool compact;
  final ValueChanged<bool> onModeChanged;
  final Widget child;

  const _AuthCard({
    required this.isRegistrationMode,
    required this.compact,
    required this.onModeChanged,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Container(
        padding: EdgeInsets.all(compact ? 18 : 22),
        decoration: BoxDecoration(
          color: _C.panel,
          borderRadius: BorderRadius.circular(22),
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
          children: [
            _ModeSwitch(
              isRegistration: isRegistrationMode,
              onChanged: onModeChanged,
            ),
            SizedBox(height: compact ? 18 : 22),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(
                  sizeFactor: animation,
                  axisAlignment: -1,
                  child: child,
                ),
              ),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Mode switch ─────────────────────────

class _ModeSwitch extends StatelessWidget {
  final bool isRegistration;
  final ValueChanged<bool> onChanged;

  const _ModeSwitch({required this.isRegistration, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _C.fieldBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _SwitchTab(
            label: 'Вхід',
            icon: Icons.login_rounded,
            selected: !isRegistration,
            onTap: () => onChanged(false),
          ),
          _SwitchTab(
            label: 'Реєстрація',
            icon: Icons.person_add_alt_1,
            selected: isRegistration,
            onTap: () => onChanged(true),
          ),
        ],
      ),
    );
  }
}

class _SwitchTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _SwitchTab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [_C.softBlue, _C.blue],
                  )
                : null,
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: _C.blue.withOpacity(0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 17,
                color: selected ? Colors.white : _C.textMuted,
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : _C.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Field ─────────────────────────

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscureText;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  const _Field({
    required this.controller,
    required this.label,
    required this.icon,
    this.obscureText = false,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      style: const TextStyle(
        color: _C.textDark,
        fontWeight: FontWeight.w600,
        fontSize: 15,
      ),
      cursorColor: _C.blue,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(
          color: _C.textMuted,
          fontWeight: FontWeight.w500,
        ),
        floatingLabelStyle: const TextStyle(
          color: _C.blue,
          fontWeight: FontWeight.w700,
        ),
        prefixIcon: Icon(icon, color: _C.textMuted, size: 20),
        filled: true,
        fillColor: _C.fieldBg,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _C.blue, width: 1.6),
        ),
      ),
    );
  }
}

// ───────────────────────── Message box ─────────────────────────

class _MessageBox extends StatelessWidget {
  final String text;
  final bool isError;

  const _MessageBox({required this.text, required this.isError});

  @override
  Widget build(BuildContext context) {
    final color = isError ? const Color(0xFFE5484D) : _C.emerald;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.check_circle_outline,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Primary button ─────────────────────────

class _PrimaryButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool loading;
  final Color accent;
  final Color soft;
  final VoidCallback? onTap;

  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.loading,
    required this.accent,
    required this.soft,
    required this.onTap,
  });

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;

    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: enabled ? 1.0 : 0.7,
          duration: const Duration(milliseconds: 160),
          child: Container(
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [widget.soft, widget.accent],
              ),
              boxShadow: [
                BoxShadow(
                  color: widget.accent.withOpacity(0.40),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.loading)
                  const SizedBox(
                    width: 19,
                    height: 19,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                else
                  Icon(widget.icon, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text(
                  widget.label,
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                    color: Colors.white,
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

// ───────────────────────── Footer ─────────────────────────

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return Text(
      'by Dimon VR · DC Link',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        fontStyle: FontStyle.italic,
        letterSpacing: 0.3,
        color: Colors.white.withOpacity(0.4),
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