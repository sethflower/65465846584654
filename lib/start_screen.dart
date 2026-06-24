import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

class StartScreen extends StatelessWidget {
  const StartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.deepBlue,
      body: Stack(
        children: [
          const Positioned.fill(child: _Background()),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final h = constraints.maxHeight;

                final isVerySmall = h < 600;
                final isSmall = h < 720;
                final isNarrow = w < 370;

                final hPad = isNarrow ? 16.0 : 24.0;
                final contentWidth = math.min(w - hPad * 2, 420.0);

                return Center(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(hPad, 24, hPad, 28),
                    child: SizedBox(
                      width: contentWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(height: isVerySmall ? 16 : (isSmall ? 32 : 56)),

                          const _Brand(),

                          SizedBox(height: isVerySmall ? 28 : 44),

                          _SectionLabel(isNarrow: isNarrow),

                          SizedBox(height: isVerySmall ? 14 : 18),

                          _ModuleCard(
                            index: '01',
                            title: 'BoxID-ТТН',
                            subtitle: 'Маркування посилок НП',
                            accent: _C.blue,
                            soft: _C.softBlue,
                            icon: Icons.qr_code_scanner_rounded,
                            compact: isVerySmall,
                            onTap: () => Navigator.pushReplacementNamed(
                              context,
                              '/login',
                            ),
                          ),

                          SizedBox(height: isVerySmall ? 12 : 16),

                          _ModuleCard(
                            index: '02',
                            title: 'СканПак',
                            subtitle: 'Пакування посилок',
                            accent: _C.emerald,
                            soft: _C.mint,
                            icon: Icons.inventory_2_rounded,
                            compact: isVerySmall,
                            onTap: () => Navigator.pushReplacementNamed(
                              context,
                              '/scanpak/login',
                            ),
                          ),

                          SizedBox(height: isVerySmall ? 22 : 36),

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
}

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
}

// ───────────────────────── Brand / Logo ─────────────────────────

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_C.softBlue, _C.blue],
            ),
            boxShadow: [
              BoxShadow(
                color: _C.blue.withOpacity(0.45),
                blurRadius: 28,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: const Icon(
            Icons.warehouse_rounded,
            color: Colors.white,
            size: 36,
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'DC Link',
          style: TextStyle(
            fontSize: 32,
            height: 1.0,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'СКЛАДСЬКА СИСТЕМА',
          style: TextStyle(
            fontSize: 12,
            height: 1.0,
            fontWeight: FontWeight.w600,
            letterSpacing: 3.2,
            color: Colors.white.withOpacity(0.55),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── Section label ─────────────────────────

class _SectionLabel extends StatelessWidget {
  final bool isNarrow;
  const _SectionLabel({required this.isNarrow});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          'Оберіть модуль',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: Colors.white.withOpacity(0.85),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            height: 1,
            color: Colors.white.withOpacity(0.12),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── Module card ─────────────────────────

class _ModuleCard extends StatefulWidget {
  final String index;
  final String title;
  final String subtitle;
  final Color accent;
  final Color soft;
  final IconData icon;
  final bool compact;
  final VoidCallback onTap;

  const _ModuleCard({
    required this.index,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.soft,
    required this.icon,
    required this.compact,
    required this.onTap,
  });

  @override
  State<_ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<_ModuleCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(20);
    final pad = widget.compact ? 16.0 : 18.0;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.all(pad),
          decoration: BoxDecoration(
            color: _C.panel,
            borderRadius: radius,
            border: Border.all(
              color: widget.accent.withOpacity(_pressed ? 0.5 : 0.0),
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: _C.deepBlue.withOpacity(0.28),
                blurRadius: 26,
                offset: const Offset(0, 14),
              ),
              BoxShadow(
                color: widget.accent.withOpacity(0.16),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              // Icon block
              Container(
                width: widget.compact ? 48 : 54,
                height: widget.compact ? 48 : 54,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [widget.soft, widget.accent],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: widget.accent.withOpacity(0.4),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Icon(
                  widget.icon,
                  color: Colors.white,
                  size: widget.compact ? 24 : 27,
                ),
              ),

              const SizedBox(width: 16),

              // Texts
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          widget.index,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: widget.accent,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _C.textMuted.withOpacity(0.4),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: widget.compact ? 16 : 17,
                        height: 1.05,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: _C.textDark,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.1,
                        fontWeight: FontWeight.w500,
                        color: _C.textMuted,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 10),

              // Arrow
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.accent.withOpacity(0.10),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.arrow_forward_rounded,
                  size: 18,
                  color: widget.accent,
                ),
              ),
            ],
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
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(99),
            color: Colors.white.withOpacity(0.08),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: _C.mint,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Система працює',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withOpacity(0.75),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '© DC Link · v1.0',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
            color: Colors.white.withOpacity(0.4),
          ),
        ),
      ],
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
        // Base gradient
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

        // Subtle grid / mesh
        const Positioned.fill(
          child: CustomPaint(painter: _MeshPainter()),
        ),

        // Glow top-left
        Positioned(
          left: -130,
          top: -120,
          child: _Glow(size: 320, color: _C.softBlue.withOpacity(0.32)),
        ),

        // Glow bottom-right
        Positioned(
          right: -150,
          bottom: -130,
          child: _Glow(size: 400, color: _C.mint.withOpacity(0.26)),
        ),

        // Soft overlay to darken top for contrast
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

    // Diagonal subtle lines
    for (double x = -size.height; x < size.width; x += step * 2) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        linePaint,
      );
    }

    // Faint dots
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