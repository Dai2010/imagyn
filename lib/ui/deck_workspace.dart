import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/studio.dart';
import '../l10n/strings.dart';

/// The deck the Agent is writing, rendered as it changes.
///
/// The tools mutate one [Deck] in memory and call `notifyListeners`; this page
/// diffs that list on every notification so a page that arrives slides in and
/// one the model drops slides out, instead of the whole deck repainting.
class DeckWorkspacePage extends StatelessWidget {
  const DeckWorkspacePage({
    super.key,
    required this.studio,
    required this.deck,
  });
  final Studio studio;
  final Deck deck;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return ListenableBuilder(
      listenable: studio,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                deck.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 17,
                ),
              ),
              Text(
                '${deck.slides.length} ${s.t('slidesUnit')} · ${deck.aspectRatio}'
                '${deck.finished ? ' · ${s.t('deckFinished')}' : ''}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: DeckWorkspace(studio: studio, deck: deck),
        ),
      ),
    );
  }
}

class DeckWorkspace extends StatefulWidget {
  const DeckWorkspace({
    super.key,
    required this.studio,
    required this.deck,
  });
  final Studio studio;
  final Deck deck;

  @override
  State<DeckWorkspace> createState() => _DeckWorkspaceState();
}

class _DeckWorkspaceState extends State<DeckWorkspace> {
  final _list = GlobalKey<AnimatedListState>();
  final _items = <_Item>[];
  final _assets = <String, Future<Asset?>>{};

  /// A slide has no id of its own: the tools append and replace immutable
  /// [Slide] objects. An Expando gives each object identity a stable number,
  /// which is what lets a replacement animate as a swap instead of a rebuild.
  final _keys = Expando<int>('slide-key');
  var _nextKey = 0;

  /// The count AnimatedList starts from while it has not been built yet. Every
  /// later difference travels through insertItem/removeItem; a changing
  /// initialItemCount would make AnimatedList apply the same delta twice.
  var _initialCount = 0;
  var _placeholderVisible = false;
  var _signature = '';

  Studio get studio => widget.studio;
  Deck get deck => widget.deck;
  Strings get s => Strings.of(context);

  Duration get _insert => MediaQuery.of(context).disableAnimations
      ? Duration.zero
      : const Duration(milliseconds: 200);
  Duration get _remove => MediaQuery.of(context).disableAnimations
      ? Duration.zero
      : const Duration(milliseconds: 180);

  /// A deck still being written shows a placeholder page at the end, so an
  /// empty workspace says "working" rather than "broken".
  bool get _waiting =>
      !deck.finished && (studio.busy || deck.slides.isEmpty);

  bool get _building =>
      studio.busy && studio.activeDeck?.id == deck.id && !deck.finished;

  @override
  void initState() {
    super.initState();
    studio.addListener(_sync);
    _fill();
    _placeholderVisible = _waiting;
    _initialCount = _items.length + (_placeholderVisible ? 1 : 0);
    _signature = _signal();
  }

  @override
  void didUpdateWidget(DeckWorkspace old) {
    super.didUpdateWidget(old);
    if (old.studio != widget.studio) {
      old.studio.removeListener(_sync);
      widget.studio.addListener(_sync);
    }
  }

  @override
  void dispose() {
    studio.removeListener(_sync);
    super.dispose();
  }

  void _fill() {
    _items
      ..clear()
      ..addAll([for (final slide in deck.slides) _Item(_keyOf(slide), slide)]);
  }

  int _keyOf(Slide slide) => _keys[slide] ??= _nextKey++;

  /// Everything a repaint depends on besides the slide text itself, which is
  /// immutable per slide object. Streaming a reply notifies this page many
  /// times a second; without this guard each of those would rebuild every page.
  String _signal() =>
      '${[for (final item in _items) item.key].join(',')}|$_placeholderVisible|'
      '${deck.finished}|${studio.busy}|${studio.runningTool}|'
      '${studio.activeDeck?.id}';

  void _sync() {
    if (!mounted) return;
    final slides = deck.slides;
    final keys = [for (final slide in slides) _keyOf(slide)];
    final wanted = keys.toSet();
    final state = _list.currentState;
    // Removals run from the end so the indices in front of them stay valid.
    for (var i = _items.length - 1; i >= 0; i--) {
      if (wanted.contains(_items[i].key)) continue;
      final removed = _items.removeAt(i);
      final number = i + 1;
      state?.removeItem(
        i,
        (context, animation) => _exit(removed, number, animation),
        duration: _remove,
      );
    }
    for (var i = 0; i < keys.length; i++) {
      if (i < _items.length && _items[i].key == keys[i]) {
        _items[i].slide = slides[i];
        continue;
      }
      _items.insert(i, _Item(keys[i], slides[i]));
      state?.insertItem(i, duration: _insert);
    }
    // The placeholder page trails the real ones, so it enters and leaves at
    // the end of the list.
    final waiting = _waiting;
    if (waiting != _placeholderVisible) {
      final index = _items.length;
      _placeholderVisible = waiting;
      if (waiting) {
        state?.insertItem(index, duration: _insert);
      } else {
        state?.removeItem(
          index,
          (context, animation) => _exitSkeleton(animation),
          duration: _remove,
        );
      }
    }
    if (state == null) {
      _initialCount = _items.length + (_placeholderVisible ? 1 : 0);
    }
    final signature = _signal();
    if (signature == _signature) return;
    _signature = signature;
    setState(() {});
  }

  Future<Asset?> _asset(String id) =>
      _assets[id] ??= studio.store.asset(id);

  void _open(Slide slide, int number) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Stack(
            children: [
              AspectRatio(
                aspectRatio: _ratio,
                child: _SlideCard(
                  slide: slide,
                  number: number,
                  asset: slide.imageId == null
                      ? null
                      : _asset(slide.imageId!),
                  large: true,
                  studio: studio,
                ),
              ),
              PositionedDirectional(
                top: 4,
                end: 4,
                child: IconButton.filledTonal(
                  tooltip: s.t('close'),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double get _ratio => deck.aspectRatio == '4:3' ? 4 / 3 : 16 / 9;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Column(
          children: [
            Expanded(
              child: AnimatedList(
                key: _list,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                initialItemCount: _initialCount,
                itemBuilder: (context, index, animation) {
                  if (index >= _items.length) {
                    return _enter(_placeholder(), animation);
                  }
                  final item = _items[index];
                  return _enter(
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: GestureDetector(
                        onTap: () => _open(item.slide, index + 1),
                        child: AspectRatio(
                          aspectRatio: _ratio,
                          child: _SlideCard(
                            slide: item.slide,
                            number: index + 1,
                            asset: item.slide.imageId == null
                                ? null
                                : _asset(item.slide.imageId!),
                            studio: studio,
                          ),
                        ),
                      ),
                    ),
                    animation,
                  );
                },
              ),
            ),
            AnimatedSize(
              duration: _insert,
              alignment: AlignmentDirectional.topStart,
              child: _building ? _status() : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _status() {
    final illustrating = studio.runningTool == 'generate_image';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s.t(illustrating ? 'deckIllustrating' : 'deckBuilding'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Text(
            '${deck.slides.length} ${s.t('slidesUnit')}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }

  /// The page that has not arrived yet. Its label changes once the model has
  /// written at least one slide, so an empty deck and a deck mid-edit do not
  /// claim to be waiting for the same thing.
  Widget _placeholder() => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: AspectRatio(
      aspectRatio: _ratio,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 26,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 10),
              Text(
                s.t(deck.slides.isEmpty ? 'deckEmpty' : 'deckBuilding'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  /// New pages grow into place; the one being removed shrinks back out.
  Widget _enter(Widget child, Animation<double> animation) {
    final curved = animation.drive(CurveTween(curve: Curves.easeOutCubic));
    return SizeTransition(
      sizeFactor: curved,
      axisAlignment: -1,
      child: FadeTransition(opacity: curved, child: child),
    );
  }

  Widget _exitSkeleton(Animation<double> animation) {
    final curved = animation.drive(CurveTween(curve: Curves.easeInCubic));
    return SizeTransition(
      sizeFactor: curved,
      axisAlignment: -1,
      child: FadeTransition(opacity: curved, child: _placeholder()),
    );
  }

  Widget _exit(_Item item, int number, Animation<double> animation) {
    final curved = animation.drive(CurveTween(curve: Curves.easeInCubic));
    return SizeTransition(
      sizeFactor: curved,
      axisAlignment: -1,
      child: FadeTransition(
        opacity: curved,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: AspectRatio(
            aspectRatio: _ratio,
            child: _SlideCard(
              slide: item.slide,
              number: number,
              asset: item.slide.imageId == null
                  ? null
                  : _asset(item.slide.imageId!),
              studio: studio,
            ),
          ),
        ),
      ),
    );
  }
}

class _Item {
  _Item(this.key, this.slide);
  final int key;
  Slide slide;
}

/// One page: text on the left, the generated illustration on the right. It is
/// the same widget at thumbnail and full size so what the user taps is what
/// they get.
class _SlideCard extends StatelessWidget {
  const _SlideCard({
    required this.slide,
    required this.number,
    required this.asset,
    required this.studio,
    this.large = false,
  });
  final Slide slide;
  final int number;
  final Future<Asset?>? asset;
  final Studio studio;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final pad = (width * .055).clamp(10.0, 44.0);
          final title = large
              ? (width * .045).clamp(18.0, 40.0)
              : (width * .05).clamp(13.0, 22.0);
          final body = title * .62;
          final hasImage = asset != null;
          return Padding(
            padding: EdgeInsets.all(pad),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: hasImage ? 3 : 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        number.toString().padLeft(2, '0'),
                        style: TextStyle(
                          fontSize: body * .8,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                          color: scheme.primary,
                        ),
                      ),
                      SizedBox(height: pad * .45),
                      Text(
                        slide.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: title,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      SizedBox(height: pad * .35),
                      Expanded(
                        child: SingleChildScrollView(
                          physics: const NeverScrollableScrollPhysics(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final bullet in slide.bullets)
                                Padding(
                                  padding: EdgeInsets.only(bottom: body * .55),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Padding(
                                        padding: EdgeInsets.only(
                                          top: body * .55,
                                          right: body * .7,
                                        ),
                                        child: Container(
                                          width: body * .3,
                                          height: body * .3,
                                          decoration: BoxDecoration(
                                            color: scheme.primary,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          bullet,
                                          style: TextStyle(
                                            fontSize: body,
                                            height: 1.35,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasImage) ...[
                  SizedBox(width: pad * .8),
                  Expanded(
                    flex: 2,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(large ? 14 : 8),
                      child: SizedBox.expand(
                        child: FutureBuilder<Asset?>(
                          future: asset,
                          builder: (context, snapshot) {
                            final image = snapshot.data;
                            if (image == null) {
                              return ColoredBox(
                                color: scheme.surfaceContainerHighest,
                                child: Center(
                                  child: snapshot.connectionState ==
                                          ConnectionState.done
                                      ? Icon(
                                          Icons.image_not_supported_outlined,
                                          color: scheme.outline,
                                        )
                                      : Text(
                                          Strings.of(context).t('deckImage'),
                                          style: Theme.of(
                                            context,
                                          ).textTheme.labelSmall,
                                        ),
                                ),
                              );
                            }
                            return Image.file(
                              File(studio.store.file(image).path),
                              fit: BoxFit.cover,
                              cacheWidth: large ? 1200 : 520,
                              errorBuilder: (_, _, _) => ColoredBox(
                                color: scheme.surfaceContainerHighest,
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  color: scheme.outline,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
