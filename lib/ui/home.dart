import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import 'visuals.dart';

/// The launcher: one card per capability, so no screen has to carry another
/// feature's controls. The large first card is the everyday path; the rest are
/// one tap away without being folded into it.
class StudioHome extends StatelessWidget {
  const StudioHome({
    super.key,
    required this.onCreate,
    required this.onAgent,
    required this.onVideo,
    required this.onLibrary,
  });
  final VoidCallback onCreate, onAgent, onVideo, onLibrary;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          key: const ValueKey('studioHome'),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            _HeroCard(
              key: const ValueKey('homeCreate'),
              label: s.t('create'),
              hint: s.t('prompt'),
              onTap: onCreate,
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _Tile(
                    key: const ValueKey('homeAgent'),
                    label: s.t('agent'),
                    icon: Icons.forum_rounded,
                    onTap: onAgent,
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: _Tile(
                    key: const ValueKey('homeVideo'),
                    label: s.t('video'),
                    icon: Icons.movie_rounded,
                    onTap: onVideo,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _WideTile(
              key: const ValueKey('homeLibrary'),
              label: s.t('gallery'),
              onTap: onLibrary,
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    super.key,
    required this.label,
    required this.hint,
    required this.onTap,
  });
  final String label, hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xff5b3fc4), Color(0xff7c5ce0)]
              : [scheme.primary, scheme.secondary],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: .34),
            blurRadius: 36,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(28),
          child: SizedBox(
            height: 184,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.auto_awesome_rounded,
                        size: 34,
                        color: Colors.white,
                      ),
                      const Spacer(),
                      Icon(
                        Icons.arrow_outward_rounded,
                        color: Colors.white.withValues(alpha: .8),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: .78),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: StudioVisuals.glass(context),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(StudioVisuals.cardRadius),
          child: SizedBox(
            height: 152,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _IconBubble(icon: icon),
                  const Spacer(),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WideTile extends StatelessWidget {
  const _WideTile({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: StudioVisuals.glass(context),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(StudioVisuals.cardRadius),
          child: SizedBox(
            height: 112,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _IconBubble(icon: Icons.grid_view_rounded),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.outline,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconBubble extends StatelessWidget {
  const _IconBubble({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(icon, color: scheme.primary, size: 24),
    );
  }
}
