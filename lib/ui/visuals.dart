import 'package:flutter/material.dart';

/// The shape of the app: one purple accent, glass surfaces and a spacing scale
/// wide enough that a screen does not read as a control panel.
///
/// The blur is simulated with a translucent fill and a light border. A real
/// `BackdropFilter` over a scrolling list costs frames on the Android phones
/// this app targets, and the difference is hard to see at this opacity.
class StudioVisuals {
  const StudioVisuals._();

  static const seed = Color(0xff7c5ce0);
  static const accent = Color(0xff9b7bff);

  static const pagePadding = 20.0;
  static const gap = 16.0;
  static const gapLarge = 24.0;

  static const cardRadius = 24.0;
  static const fieldRadius = 16.0;

  static LinearGradient background(Brightness brightness) =>
      brightness == Brightness.dark
      ? const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff191324), Color(0xff120f18), Color(0xff0d0b12)],
          stops: [0, .55, 1],
        )
      : const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xfff6f1ff), Color(0xfffbfaff), Color(0xfff1ebff)],
          stops: [0, .55, 1],
        );

  /// A card fill that lets the page gradient show through, with a border just
  /// bright enough to separate it from the background.
  static BoxDecoration glass(
    BuildContext context, {
    double radius = cardRadius,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return BoxDecoration(
      color: scheme.surface.withValues(alpha: dark ? .72 : .84),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: scheme.primary.withValues(alpha: dark ? .26 : .14),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? .32 : .06),
          blurRadius: 28,
          offset: const Offset(0, 14),
        ),
        BoxShadow(
          color: scheme.primary.withValues(alpha: dark ? .10 : .06),
          blurRadius: 48,
          spreadRadius: -8,
        ),
      ],
    );
  }
}

/// Paints the two soft colour fields behind every main screen. They are cheap
/// gradients, not images, and they sit under the content rather than blurring
/// it.
class StudioPageBackground extends StatelessWidget {
  const StudioPageBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final scheme = Theme.of(context).colorScheme;
    final dark = brightness == Brightness.dark;
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: StudioVisuals.background(brightness),
            ),
          ),
        ),
        Positioned(
          top: -140,
          right: -120,
          child: _Glow(
            color: scheme.primary.withValues(alpha: dark ? .28 : .16),
            size: 360,
          ),
        ),
        Positioned(
          bottom: -180,
          left: -140,
          child: _Glow(
            color: StudioVisuals.accent.withValues(alpha: dark ? .16 : .10),
            size: 380,
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.size});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
        ),
      ),
    ),
  );
}
