import 'package:flutter/material.dart';

import 'app_design.dart';

class StartScreen extends StatelessWidget {
  const StartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isCompact = width < 760;
    final panelWidth = isCompact ? double.infinity : 430.0;

    return Scaffold(
      body: ResponsiveShell(
        child: GlassPanel(
          child: Wrap(
            spacing: 28,
            runSpacing: 28,
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: isCompact ? double.infinity : 560,
                child: Column(
                  crossAxisAlignment: isCompact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                  children: [
                    Image.asset('assets/images/logo.png', width: isCompact ? 104 : 132, height: isCompact ? 104 : 132, errorBuilder: (_, __, ___) => const Icon(Icons.hub_outlined, size: 88, color: AppColors.blue)),
                    const SizedBox(height: 20),
                    Text('Единый центр операционных сервисов', textAlign: isCompact ? TextAlign.center : TextAlign.left, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, color: AppColors.navy)),
                    const SizedBox(height: 12),
                    Text('Выберите рабочий модуль. Интерфейс адаптирован для терминалов, планшетов, ноутбуков и телефонов.', textAlign: isCompact ? TextAlign.center : TextAlign.left, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppColors.slate, height: 1.45)),
                    const SizedBox(height: 20),
                    const Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [StatusPill(label: 'Адаптивно', icon: Icons.devices, color: AppColors.blue), StatusPill(label: 'Быстрое сканирование', icon: Icons.qr_code_scanner, color: AppColors.emerald), StatusPill(label: 'Офлайн-режим', icon: Icons.cloud_sync, color: AppColors.amber)]),
                  ],
                ),
              ),
              SizedBox(
                width: panelWidth,
                child: SectionCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                    Text('Вход в систему', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900, color: AppColors.navy)),
                    const SizedBox(height: 16),
                    FilledButton.icon(onPressed: () => Navigator.pushReplacementNamed(context, '/login'), icon: const Icon(Icons.inventory_2_outlined), label: const Text('TrackingApp')),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(onPressed: () => Navigator.pushReplacementNamed(context, '/scanpak/login'), icon: const Icon(Icons.qr_code_scanner), label: const Text('СканПак')),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}