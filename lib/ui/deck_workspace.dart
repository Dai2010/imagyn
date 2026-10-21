import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/studio.dart';
import '../l10n/strings.dart';

/// The deck the Agent is writing, rendered as it changes.
///
/// The tools mutate one [Deck] in memory and call `notifyListeners`; this page
/// diffs that list on every notification so a page that arrives slides in and
/// one the model drops slides out, instead of the whole deck repainting.
class DeckWorkspacePage extends StatefulWidget {
  const DeckWorkspacePage({
    super.key,
    required this.studio,
    required this.deck,
  });
  final Studio studio;
  final Deck deck;

  @override
  State<DeckWorkspacePage> createState() => _DeckWorkspacePageState();
}

class _DeckWorkspacePageState extends State<DeckWorkspacePage> {
  var _exporting = false;

  Studio get studio => widget.studio;
  Deck get deck => widget.deck;

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final messenger = ScaffoldMessenger.of(context);
    final s = Strings.of(context);
    try {
      await studio.exportDeck(deck);
      messenger.showSnackBar(SnackBar(content: Text(s.t('saved'))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(s.t(errorCode(e)))));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Shares the same bytes Export writes, without leaving a copy in Downloads:
  /// the share sheet is also how the deck is opened in PowerPoint or WPS.
  Future<void> _share() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final messenger = ScaffoldMessenger.of(context);
    final s = Strings.of(context);
    try {
      await studio.shareDeck(deck);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(s.t(errorCode(e)))));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

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
          actions: [
            IconButton(
              tooltip: s.t('share'),
              onPressed: deck.slides.isEmpty || _exporting ? null : _share,
              icon: const Icon(Icons.ios_share_rounded),
            ),
            if (_exporting)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              IconButton(
                tooltip: s.t('exportDeck'),
                onPressed: deck.slides.isEmpty ? null : _export,
                icon: const Icon(Icons.download_outlined),
              ),
          ],
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
      '${[for (final item in _items) '${item.key}:${item.slide.backgroundImageId ?? ''}:${item.slide.backgroundColor ?? ''}:${Object.hashAll(item.slide.elements)}'].join(',')}'
      '|${deck.backgroundImageId ?? ''}|${deck.backgroundColor ?? ''}|'
      '$_placeholderVisible|'
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

  /// The background this page uses, if any. Null keeps the plain card.
  Future<Asset?>? _background(Slide slide) {
    final id = deck.backgroundFor(slide);
    return id == null ? null : _asset(id);
  }

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
                  background: _background(slide),
                  backgroundColor: deck.backgroundColorFor(slide),
                  large: true,
                  studio: studio,
                  points: _points,
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

  /// The page width in points, matching [deckSize] in the writer: element
  /// font sizes are literal, so this is what makes preview and export agree.
  double get _points => deck.aspectRatio == '4:3' ? 720 : 960;

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
                            background: _background(item.slide),
                            backgroundColor: deck.backgroundColorFor(
                              item.slide,
                            ),
                            studio: studio,
                            points: _points,
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
      alignment: Alignment.topCenter,
      child: FadeTransition(opacity: curved, child: child),
    );
  }

  Widget _exitSkeleton(Animation<double> animation) {
    final curved = animation.drive(CurveTween(curve: Curves.easeInCubic));
    return SizeTransition(
      sizeFactor: curved,
      alignment: Alignment.topCenter,
      child: FadeTransition(opacity: curved, child: _placeholder()),
    );
  }

  Widget _exit(_Item item, int number, Animation<double> animation) {
    final curved = animation.drive(CurveTween(curve: Curves.easeInCubic));
    return SizeTransition(
      sizeFactor: curved,
      alignment: Alignment.topCenter,
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
              background: _background(item.slide),
              backgroundColor: deck.backgroundColorFor(item.slide),
              studio: studio,
              points: _points,
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
    required this.points,
    this.background,
    this.backgroundColor,
    this.large = false,
  });
  final Slide slide;
  final int number;
  final Future<Asset?>? asset;
  final Future<Asset?>? background;

  /// Solid page colour, used only when no background picture resolves.
  final String? backgroundColor;
  final Studio studio;

  /// The page width in points, 960 for 16:9 and 720 for 4:3. Element font
  /// sizes are literal points, so this is what keeps the preview and the
  /// exported `.pptx` the same size.
  final double points;
  final bool large;

  /// A page with free-form elements follows the exported file's light page
  /// instead of the themed card, because element colours are literal: dark
  /// text has to stay readable while the user is building it.
  bool get _freeForm => slide.elements.isNotEmpty;

  /// Tables and charts share the bounded canvas, so their layout stays stable
  /// at thumbnail and dialog sizes.
  bool get _hasStack => slide.allTables.isNotEmpty || slide.chart != null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = LayoutBuilder(
      builder: (context, constraints) {
        if (_hasStack) {
          // A bounded canvas keeps the table's relative layout stable at
          // thumbnail and dialog size, including on a narrow phone.
          const width = 960.0;
          final height = width * constraints.maxHeight / constraints.maxWidth;
          return FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: width,
              height: height,
              child: _content(context, width, height),
            ),
          );
        }
        return _content(
          context,
          constraints.maxWidth,
          constraints.maxHeight,
        );
      },
    );
    return Material(
      color: background == null && backgroundColor != null
          ? _color(backgroundColor!)
          : _freeForm
          ? const Color(0xFFFBFAFE)
          : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: background == null
          ? content
          : Stack(
              fit: StackFit.expand,
              children: [
                _backgroundImage(context),
                // The same idea as the scrim in the exported deck: keep the
                // themed text readable without hiding the picture entirely.
                ColoredBox(color: scheme.surface.withValues(alpha: .62)),
                content,
              ],
            ),
    );
  }

  /// Text inks follow the page: the exported deck is light, so a free-form
  /// page uses the same dark greys the writer puts into the file.
  Color _ink(BuildContext context) => _freeForm
      ? const Color(0xFF1F1B2E)
      : Theme.of(context).colorScheme.onSurface;
  Color _mutedInk(BuildContext context) => _freeForm
      ? const Color(0xFF3B3650)
      : Theme.of(context).colorScheme.onSurfaceVariant;

  Widget _backgroundImage(BuildContext context) => FutureBuilder<Asset?>(
    future: background,
    builder: (context, snapshot) {
      final image = snapshot.data;
      if (image == null) {
        return ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerLow);
      }
      return Image.file(
        File(studio.store.file(image).path),
        fit: BoxFit.cover,
        cacheWidth: large ? 1600 : 700,
        errorBuilder: (_, _, _) =>
            ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerLow),
      );
    },
  );

  Widget _content(BuildContext context, double width, double height) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _layout(context, width),
        if (slide.elements.isNotEmpty) _elements(context, width, height),
      ],
    );
  }

  /// Free-form shapes, positioned by the same fractions the writer uses, so a
  /// page looks the same here and in PowerPoint.
  Widget _elements(BuildContext context, double width, double height) {
    final borderWidth = math.max(1.0, width / points);
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final element in slide.elements)
          Positioned(
            left: element.x * width,
            top: element.y * height,
            width: math.max(1, element.width * width),
            height: math.max(1, element.height * height),
            child: element.kind == SlideElementKind.text
                ? _textElement(context, element, width, height, borderWidth)
                : _imageElement(
                    context,
                    element,
                    width,
                    height,
                    borderWidth,
                  ),
          ),
      ],
    );
  }

  Widget _textElement(
    BuildContext context,
    SlideElement element,
    double width,
    double height,
    double borderWidth,
  ) {
    final boxWidth = element.width * width;
    final boxHeight = element.height * height;
    final size = element.fontSize * width / points;
    final scale = width / points;
    final double pad = element.padding == null
        ? math.max(2.0, size * .25)
        : element.padding! * scale;
    final align = switch (element.align) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      _ => TextAlign.left,
    };
    final fill = element.fill == null ? null : _color(element.fill!);
    final gradientEnd = element.fill2 == null
        ? null
        : _color(element.fill2!);
    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: gradientEnd == null ? fill : null,
        gradient: gradientEnd == null || fill == null
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [fill, gradientEnd],
              ),
        border: element.border == null
            ? null
            : Border.all(color: _color(element.border!), width: borderWidth),
        borderRadius: BorderRadius.circular(
          element.radius * math.min(boxWidth, boxHeight),
        ),
        boxShadow: element.shadow
            ? [
                BoxShadow(
                  color: const Color(0x33000000),
                  blurRadius: size * .6,
                  offset: Offset(0, size * .12),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Align(
          alignment: Alignment.center,
          child: SizedBox(
            width: double.infinity,
            child: Text(
              element.text,
              textAlign: align,
              style: TextStyle(
                fontSize: size,
                height: element.lineSpacing,
                fontFamily: element.font,
                fontStyle: element.italic ? FontStyle.italic : null,
                fontWeight: element.bold
                    ? FontWeight.w700
                    : FontWeight.w400,
                letterSpacing: element.letterSpacing * scale,
                color: _color(element.color),
              ),
            ),
          ),
        ),
      ),
    );
    return element.rotation == 0
        ? box
        : Transform.rotate(
            angle: element.rotation * math.pi / 180,
            child: box,
          );
  }

  Widget _imageElement(
    BuildContext context,
    SlideElement element,
    double width,
    double height,
    double borderWidth,
  ) {
    final radius = element.radius *
        math.min(element.width * width, element.height * height);
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(color: scheme.surfaceContainerHighest);
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: element.border == null
            ? null
            : Border.all(color: _color(element.border!), width: borderWidth),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: FutureBuilder<Asset?>(
          future: _asset(element.imageId),
          builder: (context, snapshot) {
            final image = snapshot.data;
            if (image == null) return placeholder;
            return SizedBox.expand(
              child: Image.file(
                File(studio.store.file(image).path),
                fit: element.fit == 'contain'
                    ? BoxFit.contain
                    : BoxFit.cover,
                cacheWidth: large ? 1200 : 520,
                errorBuilder: (_, _, _) => placeholder,
              ),
            );
          },
        ),
      ),
    );
  }

  Future<Asset?> _asset(String? id) =>
      id == null ? Future.value() : studio.store.asset(id);

  static Color _color(String hex) =>
      Color(int.parse('FF$hex', radix: 16));

  Widget _layout(BuildContext context, double width) {
    final scheme = Theme.of(context).colorScheme;
    final pad = (width * .055).clamp(10.0, 44.0);
    final title = _hasStack
        ? 40.0
        : large
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
                    color: _ink(context),
                  ),
                ),
                SizedBox(height: pad * .35),
                Expanded(child: _body(context, body)),
                if (large && slide.notes.isNotEmpty) ...[
                  SizedBox(height: pad * .35),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(
                      horizontal: pad * .4,
                      vertical: pad * .3,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(
                        alpha: .7,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      slide.notes,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: body * .8,
                        height: 1.35,
                        color: _mutedInk(context),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (hasImage) ...[
            SizedBox(width: pad * .8),
            Expanded(
              flex: 2,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(large ? 14 : 8),
                child: SizedBox.expand(child: _image(context)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body(BuildContext context, double fontSize) {
    final tables = slide.allTables;
    final chart = slide.chart;
    if (tables.isEmpty && chart == null) return _bullets(context, fontSize);
    final hasBullets = slide.bullets.any((text) => text.trim().isNotEmpty);
    final shared = tables.isNotEmpty && chart != null;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasBullets) ...[
            SizedBox(
              height: constraints.maxHeight * (shared ? .28 : .35),
              child: _bullets(context, fontSize),
            ),
            const SizedBox(height: 12),
          ],
          if (shared) ...[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < tables.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    Expanded(child: _table(context, tables[i])),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(child: _chart(context, chart!)),
          ] else if (tables.isNotEmpty) ...[
            for (var i = 0; i < tables.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              Expanded(child: _table(context, tables[i])),
            ],
          ] else
            Expanded(child: _chart(context, chart!)),
        ],
      ),
    );
  }

  Widget _bullets(BuildContext context, double body) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < slide.bullets.length; i++)
            if (!_hasStack || slide.bullets[i].trim().isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  bottom: body * .55,
                  left: body *
                      .9 *
                      (i < slide.bulletLevels.length
                          ? slide.bulletLevels[i]
                          : 0),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                        slide.bullets[i],
                        style: TextStyle(
                          fontSize: body,
                          height: 1.35,
                          color: _mutedInk(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _table(BuildContext context, SlideTable table) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final rowHeight = constraints.maxHeight / table.rows.length;
        final cellWidth = constraints.maxWidth / table.columnCount;
        return Table(
          border: TableBorder.all(color: scheme.outlineVariant),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            for (var row = 0; row < table.rows.length; row++)
              TableRow(
                decoration: BoxDecoration(
                  color: table.headerRow && row == 0
                      ? scheme.primaryContainer
                      : row.isEven
                      ? scheme.surfaceContainer
                      : scheme.surfaceContainerLow,
                ),
                children: [
                  for (final text in table.rows[row])
                    SizedBox(
                      height: rowHeight,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: (cellWidth * .1).clamp(2.0, 10.0),
                          vertical: (rowHeight * .15).clamp(2.0, 8.0),
                        ),
                        child: LayoutBuilder(
                          // Keep the grid at full width while fitting complete
                          // cell text into its row. Dense tables stay bounded;
                          // the model can split them across slides for legibility.
                          builder: (context, cell) => FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: cell.maxWidth,
                              child: Text(
                                text,
                                style: TextStyle(
                                  fontSize: (24.0 - table.columnCount).clamp(
                                    14.0,
                                    20.0,
                                  ),
                                  height: 1.25,
                                  fontWeight: table.headerRow && row == 0
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: table.headerRow && row == 0
                                      ? scheme.onPrimaryContainer
                                      : _ink(context),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }

  Widget _chart(BuildContext context, SlideChart chart) {
    final scheme = Theme.of(context).colorScheme;
    final ink = _ink(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: _freeForm
            ? const Color(0xFFF4F2FA)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chart.title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                chart.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 18,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
              ),
            ),
          Expanded(
            child: CustomPaint(
              painter: _ChartPainter(
                chart: chart,
                palette: [scheme.primary, scheme.tertiary, scheme.secondary],
                ink: ink,
                grid: scheme.outlineVariant,
                surface: scheme.surface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _image(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<Asset?>(
      future: asset,
      builder: (context, snapshot) {
        final image = snapshot.data;
        if (image == null) {
          return ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: Center(
              child: snapshot.connectionState == ConnectionState.done
                  ? Icon(
                      Icons.image_not_supported_outlined,
                      color: scheme.outline,
                    )
                  : Text(
                      Strings.of(context).t('deckImage'),
                      style: Theme.of(context).textTheme.labelSmall,
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
            child: Icon(Icons.broken_image_outlined, color: scheme.outline),
          ),
        );
      },
    );
  }
}

/// Draws the chart inside the preview card. Values come from the same
/// [SlideChart] the exporter writes, so shapes and proportions match.
class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.chart,
    required this.palette,
    required this.ink,
    required this.grid,
    required this.surface,
  });

  final SlideChart chart;
  final List<Color> palette;
  final Color ink;
  final Color grid;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 2 || size.height < 2) return;
    switch (chart.kind) {
      case 'pie':
        _pie(canvas, size);
      case 'line':
        _line(canvas, size);
      default:
        _bars(canvas, size);
    }
  }

  double _labelSize(Size size) =>
      (size.height * .075).clamp(8.0, 13.0).toDouble();

  Rect _plot(Size size) {
    final label = _labelSize(size);
    return Rect.fromLTRB(
      size.width * .04,
      size.height * .06,
      size.width * .99,
      math.max(size.height * .2, size.height - label * 1.8),
    );
  }

  ({double min, double max}) _bounds() {
    var min = 0.0;
    var max = 0.0;
    for (final series in chart.series) {
      for (final value in series.values) {
        min = math.min(min, value);
        max = math.max(max, value);
      }
    }
    if (max == min) max = min + 1;
    return (min: min, max: max);
  }

  double _y(double value, Rect plot, ({double min, double max}) bounds) =>
      plot.bottom -
      (value - bounds.min) / (bounds.max - bounds.min) * plot.height;

  void _grid(Canvas canvas, Rect plot) {
    final paint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = plot.top + plot.height * i / 3;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), paint);
    }
  }

  void _category(
    Canvas canvas,
    int index,
    double center,
    double width,
    Size size,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: chart.categories[index],
        style: TextStyle(fontSize: _labelSize(size), color: ink),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1.0, width));
    painter.paint(
      canvas,
      Offset(center - painter.width / 2, size.height - painter.height),
    );
  }

  void _bars(Canvas canvas, Size size) {
    final bounds = _bounds();
    final plot = _plot(size);
    _grid(canvas, plot);
    final slot = plot.width / chart.categories.length;
    final barWidth = slot * .7 / chart.series.length;
    final paint = Paint()..style = PaintingStyle.fill;
    final zeroY = _y(0, plot, bounds);
    for (var i = 0; i < chart.categories.length; i++) {
      final left = plot.left + slot * i + slot * .15;
      for (var s = 0; s < chart.series.length; s++) {
        final y = _y(chart.series[s].values[i], plot, bounds);
        paint.color = palette[s % palette.length];
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              left + barWidth * s,
              math.min(y, zeroY),
              math.max(1.0, barWidth * .86),
              math.max(1.0, (y - zeroY).abs()),
            ),
            const Radius.circular(2),
          ),
          paint,
        );
      }
      _category(canvas, i, left + slot * .35, slot, size);
    }
  }

  void _line(Canvas canvas, Size size) {
    final bounds = _bounds();
    final plot = _plot(size);
    _grid(canvas, plot);
    final step = plot.width / chart.categories.length;
    for (var s = 0; s < chart.series.length; s++) {
      final series = chart.series[s];
      final color = palette[s % palette.length];
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      final points = <Offset>[];
      for (var i = 0; i < series.values.length; i++) {
        final point = Offset(
          plot.left + step * (i + .5),
          _y(series.values[i], plot, bounds),
        );
        points.add(point);
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(path, paint);
      final dot = Paint()..color = color;
      for (final point in points) {
        canvas.drawCircle(point, 3, dot);
      }
    }
    for (var i = 0; i < chart.categories.length; i++) {
      _category(canvas, i, plot.left + step * (i + .5), step, size);
    }
  }

  void _pie(Canvas canvas, Size size) {
    final values = chart.series.first.values;
    final total = values.fold(0.0, (sum, value) => sum + math.max(0.0, value));
    if (total <= 0) return;
    final legendWidth = size.width * .36;
    final dial = Rect.fromLTWH(0, 0, size.width - legendWidth, size.height);
    final rect = Rect.fromCircle(
      center: dial.center,
      radius: math.min(dial.width, dial.height) * .42,
    );
    final paint = Paint()..style = PaintingStyle.fill;
    final gap = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = surface;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = math.max(0.0, values[i]) / total * math.pi * 2;
      if (sweep <= 0) continue;
      paint.color = palette[i % palette.length];
      canvas.drawArc(rect, start, sweep, true, paint);
      canvas.drawArc(rect, start, sweep, true, gap);
      start += sweep;
    }
    final label = _labelSize(size);
    var y = size.height * .18;
    for (var i = 0; i < chart.categories.length; i++) {
      final swatch = Rect.fromLTWH(
        size.width - legendWidth + 4,
        y,
        math.min(10.0, label),
        math.min(10.0, label),
      );
      canvas.drawRect(swatch, Paint()..color = palette[i % palette.length]);
      final painter = TextPainter(
        text: TextSpan(
          text: chart.categories[i],
          style: TextStyle(fontSize: label, color: ink),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(1.0, legendWidth - label - 12));
      painter.paint(canvas, Offset(swatch.right + 5, y - 1));
      y += label * 1.6;
      if (y > size.height - label) break;
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.chart != chart ||
      old.ink != ink ||
      old.grid != grid ||
      old.surface != surface ||
      old.palette.length != palette.length ||
      (palette.isNotEmpty && old.palette.first != palette.first);
}
