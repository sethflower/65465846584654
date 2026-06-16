import 'package:flutter/material.dart';

import 'utils/scanpak_user_management.dart';

class ScanpakAdminPanelScreen extends StatefulWidget {
  const ScanpakAdminPanelScreen({super.key, required this.adminToken});

  final String adminToken;

  @override
  State<ScanpakAdminPanelScreen> createState() =>
      _ScanpakAdminPanelScreenState();
}

class _ScanpakAdminPanelScreenState extends State<ScanpakAdminPanelScreen> {
  List<ScanpakPendingUser> _pendingUsers = const [];
  List<ScanpakManagedUser> _registeredUsers = const [];
  Map<ScanpakUserRole, String> _apiPasswords = const {};
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final pending = await ScanpakUserApi.fetchPendingUsers(widget.adminToken);
      final users = await ScanpakUserApi.fetchUsers(widget.adminToken);
      final passwords = await ScanpakUserApi.fetchRolePasswords(
        widget.adminToken,
      );

      final normalizedPasswords = <ScanpakUserRole, String>{
        for (final role in ScanpakUserRole.values) role: passwords[role] ?? '',
      };

      if (!mounted) return;
      setState(() {
        _pendingUsers = pending;
        _registeredUsers = users;
        _apiPasswords = normalizedPasswords;
        _isLoading = false;
      });
    } on ScanpakApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.message;
        _isLoading = false;
      });
      _showError(error.message);
    } catch (_) {
      if (!mounted) return;
      const fallback = 'Не вдалося завантажити дані. Спробуйте пізніше.';
      setState(() {
        _errorMessage = fallback;
        _isLoading = false;
      });
      _showError(fallback);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _approveUser(
    ScanpakPendingUser user,
    ScanpakUserRole role,
  ) async {
    try {
      await ScanpakUserApi.approvePendingUser(
        token: widget.adminToken,
        requestId: user.id,
        role: role,
      );
      await _loadData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${user.surname} отримав(ла) роль "${role.label}"'),
        ),
      );
    } on ScanpakApiException catch (error) {
      _showError(error.message);
    } catch (_) {
      _showError('Не вдалося підтвердити користувача');
    }
  }

  Future<void> _rejectUser(ScanpakPendingUser user) async {
    try {
      await ScanpakUserApi.rejectPendingUser(
        token: widget.adminToken,
        requestId: user.id,
      );
      await _loadData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Запит від ${user.surname} відхилено')),
      );
    } on ScanpakApiException catch (error) {
      _showError(error.message);
    } catch (_) {
      _showError('Не вдалося відхилити запит');
    }
  }

  Future<void> _changeRole(
    ScanpakManagedUser user,
    ScanpakUserRole role,
  ) async {
    try {
      await ScanpakUserApi.updateUser(
        token: widget.adminToken,
        userId: user.id,
        role: role,
      );
      await _loadData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Роль користувача ${user.surname} змінена на "${role.label}"',
          ),
        ),
      );
    } on ScanpakApiException catch (error) {
      _showError(error.message);
    } catch (_) {
      _showError('Не вдалося змінити роль користувача');
    }
  }

  Future<void> _toggleUser(ScanpakManagedUser user, bool value) async {
    try {
      await ScanpakUserApi.updateUser(
        token: widget.adminToken,
        userId: user.id,
        isActive: value,
      );
      await _loadData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value
                ? 'Доступ для ${user.surname} активовано'
                : 'Доступ для ${user.surname} призупинено',
          ),
        ),
      );
    } on ScanpakApiException catch (error) {
      _showError(error.message);
    } catch (_) {
      _showError('Не вдалося змінити статус користувача');
    }
  }

  Future<void> _editApiPassword(ScanpakUserRole role) async {
    final controller = TextEditingController(text: _apiPasswords[role] ?? '');

    final result = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('API пароль для ролі "${role.label}"'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Системний пароль',
              helperText: 'Використовується для отримання токеа у бекенді',
            ),
            obscureText: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Скасувати'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Зберегти'),
            ),
          ],
        );
      },
    );

    if (result == null) return;

    try {
      await ScanpakUserApi.updateRolePassword(
        token: widget.adminToken,
        role: role,
        password: result,
      );
      await _loadData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Пароль для ролі "${role.label}" оновлено')),
      );
    } on ScanpakApiException catch (error) {
      _showError(error.message);
    } catch (_) {
      _showError('Не вдалося оновити пароль ролі');
    }
  }

  Future<void> _deleteUser(ScanpakManagedUser user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Видалити користувача'),
        content: Text(
          'Обліковий запис ${user.surname} буде повністю видалено. Користувач зможе зареєструватися знову з новим паролем.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Скасувати'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Видалити'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ScanpakUserApi.deleteUser(
        token: widget.adminToken,
        userId: user.id,
      );
      await _loadData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Користувача ${user.surname} видалено')),
      );
    } on ScanpakApiException catch (error) {
      _showError(error.message);
    } catch (_) {
      _showError('Не вдалося видалити користувача');
    }
  }

  Future<void> _revokeAccess(ScanpakManagedUser user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Призупинити доступ'),
        content: Text(
          'Користувач ${user.surname} втратить можливість входу до системи. Продовжити?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Скасувати'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Призупинити'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await _toggleUser(user, false);
  }

  Widget _buildPendingCard(ScanpakPendingUser user) {
    ScanpakUserRole selectedRole = ScanpakUserRole.operator;

    return StatefulBuilder(
      builder: (context, setInnerState) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        user.surname,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      _formatDate(user.createdAt),
                      style: Theme.of(
                        context,
                      ).textTheme.labelMedium?.copyWith(color: Colors.grey),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ScanpakUserRole>(
                  initialValue: selectedRole,
                  decoration: const InputDecoration(
                    labelText: 'Роль користувача',
                  ),
                  items: ScanpakUserRole.values
                      .map(
                        (role) => DropdownMenuItem<ScanpakUserRole>(
                          value: role,
                          child: Text(role.label),
                        ),
                      )
                      .toList(),
                  onChanged: (role) {
                    if (role == null) return;
                    setInnerState(() => selectedRole = role);
                  },
                ),
                const SizedBox(height: 12),
                Text(selectedRole.description),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () => _approveUser(user, selectedRole),
                        icon: const Icon(Icons.check),
                        label: const Text('Підтвердити'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _rejectUser(user),
                        icon: const Icon(Icons.close),
                        label: const Text('Відхилити'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildUserCard(ScanpakManagedUser user) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    user.surname,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch.adaptive(
                      value: user.isActive,
                      onChanged: (value) => _toggleUser(user, value),
                    ),
                    PopupMenuButton<_UserMenuAction>(
                      tooltip: 'Додаткові дії',
                      onSelected: (action) {
                        switch (action) {
                          case _UserMenuAction.revoke:
                            _revokeAccess(user);
                            break;
                          case _UserMenuAction.delete:
                            _deleteUser(user);
                            break;
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: _UserMenuAction.revoke,
                          child: Text('Призупинити доступ'),
                        ),
                        PopupMenuItem(
                          value: _UserMenuAction.delete,
                          child: Text('Видалити'),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.verified_user, size: 16),
                const SizedBox(width: 6),
                Text('Роль: ${user.role.label}'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.check_circle_outline, size: 16),
                const SizedBox(width: 6),
                Text(user.isActive ? 'Активний' : 'Деактивований'),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ScanpakUserRole>(
              initialValue: user.role,
              decoration: const InputDecoration(labelText: 'Змінити роль'),
              items: ScanpakUserRole.values
                  .map(
                    (role) => DropdownMenuItem<ScanpakUserRole>(
                      value: role,
                      child: Text(role.label),
                    ),
                  )
                  .toList(),
              onChanged: (role) {
                if (role == null) return;
                _changeRole(user, role);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildPasswordsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Системні паролі',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Використовуються для входу за рольовим паролем. Оновіть їх за потреби.',
            ),
            const SizedBox(height: 12),
            ...ScanpakUserRole.values.map(
              (role) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(role.label),
                subtitle: Text(role.description),
                trailing: ElevatedButton(
                  onPressed: () => _editApiPassword(role),
                  child: const Text('Змінити пароль'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh),
              label: const Text('Повторити спробу'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_pendingUsers.isNotEmpty) ...[
            Text(
              'Запити на реєстрацію',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            ..._pendingUsers.map(_buildPendingCard),
            const SizedBox(height: 24),
          ],
          Text('Користувачі', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (_registeredUsers.isEmpty)
            const Text('Поки що немає користувачів')
          else
            ..._registeredUsers.map(_buildUserCard),
          const SizedBox(height: 24),
          _buildPasswordsCard(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Адмін панель СканПак'),
        actions: [
          IconButton(
            tooltip: 'Оновити',
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }
}

enum _UserMenuAction { revoke, delete }

String _formatDate(DateTime date) {
  return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
}
