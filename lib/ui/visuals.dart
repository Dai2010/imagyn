import 'package:flutter/material.dart';

/// Google Material 3 tokens: balanced tonal surfaces, subtle elevation
/// shadows, and authentic Google adaptive palettes for light and dark modes.
class StudioVisuals {
  const StudioVisuals._();

  static const seed = Color(0xff0b57d0);
  static const accent = Color(0xffa8c7fa);

  static const pagePadding = 20.0;
  static const gap = 16.0;
  static const gapLarge = 24.0;

  static const cardRadius = 20.0;
  static const fieldRadius = 16.0;

  static LinearGradient background(Brightness brightness) =>
      brightness == Brightness.dark
      ? const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xff131314), Color(0xff181a1b)],
        )
      : const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xfff8f9fa), Color(0xffffffff)],
        );

  /// Material 3 card container with clean tonal fill and soft elevation.
  static BoxDecoration glass(
    BuildContext context, {
    double radius = cardRadius,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return BoxDecoration(
      color: dark ? scheme.surfaceContainerHigh : Colors.white,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: scheme.outlineVariant.withValues(alpha: dark ? .65 : .8),
      ),
      boxShadow: [
        BoxShadow(
          color: dark
              ? const Color(0x33000000)
              : const Color(0x0a000000),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }
}

/// A card whose shadow sits outside the layer that repaints during interaction.
/// The ink splash of a tap, or a text field's caret, repaints only the material
/// inside the boundary. Without it, each splash frame re-rasterises the blurred
/// shadow along with everything in the same layer, which reads as a stutter
/// after the tap.
class StudioSurface extends StatelessWidget {
        const StudioSurface({
                super.key,
                required this.child,
                this.radius = StudioVisuals.cardRadius,
        });
        final Widget child;
        final double radius;

        @override
        Widget build(BuildContext context) => DecoratedBox(
                decoration: StudioVisuals.glass(context, radius: radius),
                child: RepaintBoundary(
                        child: Material(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(radius),
                                clipBehavior: Clip.antiAlias,
                                child: child,
                        ),
                ),
        );
}

/// Provides the base neutral canvas behind every screen without distracting
/// corner spotlights or heavy gradients.
class StudioPageBackground extends StatelessWidget {
  const StudioPageBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: StudioVisuals.background(brightness),
      ),
      child: child,
    );
  }
}
