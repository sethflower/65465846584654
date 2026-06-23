import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'login_screen.dart';
import 'scanner_screen.dart';
import 'start_screen.dart';
import 'scanpak_home_screen.dart';
import 'scanpak_login_screen.dart';
import 'username_screen.dart';
import 'history_screen.dart';
import 'errors_screen.dart';
import 'statistics_screen.dart';
import 'admin_panel_screen.dart';
import 'utils/offline_queue.dart'; // ✅ офлайн-очередь
import 'utils/scanpak_offline_queue.dart';

class DclinkHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);

    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
      return host == 'tracking-app.dclink.ua';
    };

    return client;
  }
}

Future<void> main() async {
  // ✅ Обязательно инициализируем Flutter перед асинхронными вызовами
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ Разрешаем проблемный сертификат только для tracking-app.dclink.ua
  HttpOverrides.global = DclinkHttpOverrides();

  // ✅ Инициализация локального офлайн-хранилища
  await OfflineQueue.init();
  await ScanpakOfflineQueue.init();

  // ✅ Запуск приложения
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'TrackingApp',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),

      // ✅ Локализация — для корректного отображения дат и кнопок
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('uk', 'UA'), Locale('en', 'US')],

      // ✅ Маршруты приложения
      initialRoute: '/',
      routes: {
        '/': (context) => const StartScreen(),
        '/login': (context) => const LoginScreen(),
        '/username': (context) => UserNameScreen(),
        '/scanner': (context) => const ScannerScreen(),
        '/history': (context) => const HistoryScreen(),
        '/errors': (context) => const ErrorsScreen(),
        '/statistics': (context) => const StatisticsScreen(),
        '/scanpak/login': (context) => const ScanpakLoginScreen(),
        '/scanpak/home': (context) => const ScanpakHomeScreen(),
        '/admin': (context) {
          final token = ModalRoute.of(context)?.settings.arguments as String?;
          if (token == null || token.isEmpty) {
            return const Scaffold(
              body: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Потрібен токен адміністратора. Поверніться та увійдіть через головний екран.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            );
          }
          return AdminPanelScreen(adminToken: token);
        },
      },
    );
  }
}
