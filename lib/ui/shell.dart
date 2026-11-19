import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart' hide ImageStyle;

import '../core/models.dart';
import '../core/studio.dart';
import '../core/styles.dart';
import '../l10n/strings.dart';
import 'settings.dart';
import 'gallery.dart';
import 'image_options.dart';
import 'agent_options.dart';
import 'ask_card.dart';
import 'markdown_theme.dart';
import 'model_picker.dart';
import 'deck_workspace.dart';
import 'style_editor.dart';
import 'video.dart';
import 'visuals.dart';

class StudioShell extends StatefulWidget {
  const StudioShell({super.key, required this.studio});
  final Studio studio;
  @override
  State<StudioShell> createState() => _StudioShellState();
}

class _StudioShellState extends State<StudioShell> {
  int _page = 0;
  final _galleryPrompt = TextEditingController();
  final _agentPrompt = TextEditingController();

  Studio get studio => widget.studio;
  Strings get s => Strings.of(context);

  /// Fast, smooth transitions matching Material 3 standard motion specifications.
  Duration get _motion => MediaQuery.of(context).disableAnimations
      ? Duration.zero
      : const Duration(milliseconds: 160);

  @override
  void dispose() {
    _galleryPrompt.dispose();
    _agentPrompt.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) _notice(s.t(errorCode(e)));
    }
  }

  void _notice(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  void _settings() => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => SettingsPage(studio: studio)));
  void _switch(int page) => setState(() {
    _page = page;
  });

  /// Material 3 Fade Through transition: avoids lateral translation matrix
  /// reallocations on desktop GLES / Impeller shaders, preventing stutter.
  Widget _pageTransition(Widget child, Animation<double> animation) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: child,
    );
  }

  /// Fades and lifts a child into place the first time it is built.
  Widget _appear(String id, Widget child) => TweenAnimationBuilder<double>(
    key: ValueKey(id),
    tween: Tween(begin: 0, end: 1),
    duration: _motion,
    curve: Curves.easeOutCubic,
    builder: (context, value, child) => Opacity(
      opacity: value,
      child: Transform.translate(
        offset: Offset(0, (1 - value) * 10),
        child: child,
      ),
    ),
    child: child,
  );

  /// Gallery items fly into the full-size preview from their own grid cell.
  String _heroTag(Asset asset) => 'gallery-${asset.id}';

  @override
  Widget build(BuildContext context) {
    if (studio.onboarding) return _welcome();
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final scheme = Theme.of(context).colorScheme;
    final title = switch (_page) {
      0 => s.t('create'),
      1 => s.t('agent'),
      2 => s.t('video'),
      _ => s.t('gallery'),
    };
    final content = Column(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: _motion,
            transitionBuilder: _pageTransition,
            child: KeyedSubtree(
              key: ValueKey(_page),
              child: RepaintBoundary(
                child: switch (_page) {
                  0 => _create(),
                  1 => _conversation(),
                  2 => VideoPage(studio: studio, embedded: true),
                  _ => _gallery(),
                },
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: _motion,
          alignment: AlignmentDirectional.topStart,
          child: studio.error == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 840),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.errorContainer.withValues(alpha: .35),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: scheme.error.withValues(alpha: .4),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.t(studio.error!),
                              style: TextStyle(
                                color: scheme.error,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (studio.errorDetail != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: SelectableText(
                                  studio.errorDetail!,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        AnimatedSize(
          duration: _motion,
          alignment: AlignmentDirectional.topStart,
          child: studio.busy
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 4,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 840),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(s.t(studio.stage))),
                        TextButton(
                          onPressed: studio.cancel,
                          child: Text(s.t('cancel')),
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        if (_page == 0 || _page == 1) _composer(),
      ],
    );
    final header = Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: .65),
          ),
        ),
      ),
      child: Row(
        children: [
          if (!wide) ...[
            IconButton(
              tooltip: s.t('home'),
              onPressed: () => _switch(0),
              icon: Icon(
                Icons.auto_awesome_rounded,
                size: 20,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (_page == 1 && studio.decks.isNotEmpty)
            IconButton(
              key: const ValueKey('deckList'),
              tooltip: s.t('decks'),
              onPressed: _decks,
              icon: const Icon(Icons.slideshow_rounded, size: 20),
            ),
          if (_page == 0)
            IconButton(
              key: const ValueKey('videoPage'),
              tooltip: s.t('video'),
              onPressed: () => _switch(2),
              icon: const Icon(Icons.movie_outlined, size: 20),
            ),
          if (_page == 1) ...[
            IconButton(
              tooltip: s.t('history'),
              onPressed: studio.busy ? null : _history,
              icon: const Icon(Icons.history_rounded, size: 20),
            ),
            IconButton(
              tooltip: s.t('newChat'),
              onPressed: studio.busy
                  ? null
                  : () => _guard(studio.newConversation),
              icon: const Icon(Icons.add_comment_outlined, size: 20),
            ),
          ],
          IconButton(
            tooltip: s.t('settings'),
            onPressed: studio.busy ? null : _settings,
            icon: const Icon(Icons.settings_outlined, size: 20),
          ),
        ],
      ),
    );
    return PopScope(
      canPop: _page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _switch(0);
      },
      child: Scaffold(
        body: SafeArea(
          child: wide
              ? Row(
                  children: [
                    _sidebar(),
                    Expanded(
                      child: Column(
                        children: [
                          header,
                          Expanded(child: content),
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    header,
                    Expanded(child: content),
                  ],
                ),
        ),
        bottomNavigationBar: wide ? null : _bottomNav(),
      ),
    );
  }

  Widget _sidebar() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        width: 228,
        height: double.infinity,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 18),
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 22),
              onTap: () => _switch(0),
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.auto_awesome, color: scheme.onPrimaryContainer),
              ),
              title: Text(
                'Imagyn',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.8,
                ),
              ),
              subtitle: Text(
                'AI Studio',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 1.1,
                ),
              ),
            ),
            Divider(
              height: 42,
              indent: 20,
              endIndent: 20,
              color: scheme.outlineVariant,
            ),
            _sidebarItem(
              key: const ValueKey('homeCreate'),
              index: 0,
              icon: Icons.auto_awesome_outlined,
              activeIcon: Icons.auto_awesome_rounded,
              label: s.t('create'),
            ),
            _sidebarItem(
              key: const ValueKey('homeAgent'),
              index: 1,
              icon: Icons.forum_outlined,
              activeIcon: Icons.forum_rounded,
              label: s.t('agent'),
            ),
            _sidebarItem(
              key: const ValueKey('homeVideo'),
              index: 2,
              icon: Icons.movie_outlined,
              activeIcon: Icons.movie_rounded,
              label: s.t('video'),
            ),
            _sidebarItem(
              key: const ValueKey('homeLibrary'),
              index: 3,
              icon: Icons.grid_view_outlined,
              activeIcon: Icons.grid_view_rounded,
              label: s.t('gallery'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidebarItem({
    required Key key,
    required int index,
    required IconData icon,
    required IconData activeIcon,
    required String label,
  }) {
    final selected = _page == index;
    final scheme = Theme.of(context).colorScheme;
    final ink = selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: ListTile(
        key: key,
        selected: selected,
        onTap: () => _switch(index),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        selectedTileColor: scheme.primaryContainer,
        leading: Icon(selected ? activeIcon : icon, size: 21, color: ink),
        title: Text(
          label,
          style: TextStyle(
            color: ink,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        trailing: selected ? Icon(Icons.circle, size: 6, color: scheme.primary) : null,
      ),
    );
  }

  Widget _bottomNav() {
    final items = [
      (
        const ValueKey('homeCreate'),
        0,
        Icons.auto_awesome_outlined,
        Icons.auto_awesome_rounded,
        s.t('create'),
      ),
      (
        const ValueKey('homeAgent'),
        1,
        Icons.forum_outlined,
        Icons.forum_rounded,
        s.t('agent'),
      ),
      (
        const ValueKey('homeVideo'),
        2,
        Icons.movie_outlined,
        Icons.movie_rounded,
        s.t('video'),
      ),
      (
        const ValueKey('homeLibrary'),
        3,
        Icons.grid_view_outlined,
        Icons.grid_view_rounded,
        s.t('gallery'),
      ),
    ];
    return NavigationBar(
      selectedIndex: _page,
      onDestinationSelected: _switch,
      destinations: [
        for (final item in items)
          NavigationDestination(
            key: item.$1,
            icon: Icon(item.$3),
            selectedIcon: Icon(item.$4),
            label: item.$5,
          ),
      ],
    );
  }

  Widget _welcome() => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 58,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 28),
                Text(
                  s.t('welcome'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(s.t('welcomeText'), textAlign: TextAlign.center),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: _settings,
                  child: Text(s.t('configure')),
                ),
                TextButton(
                  onPressed: () => _guard(studio.skipOnboarding),
                  child: Text(s.t('browse')),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  /// The create page keeps only the prompt and the newest result. The grid
  /// lives in the library page, so neither screen carries the other's
  /// controls.
  Widget _create() {
        final asset = studio.gallery.isEmpty ? null : studio.gallery.first;
        if (asset == null) {
                return Center(
                        key: const ValueKey('create'),
                        child: _empty(Icons.auto_awesome_outlined, 'emptyGallery'),
                );
        }
        final scheme = Theme.of(context).colorScheme;
        return Center(
                child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 780),
                        child: ListView(
                                key: const ValueKey('create'),
                                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                                children: [
                                        GestureDetector(
                                                onTap: () => _preview(asset),
                                                child: RepaintBoundary(
                                                        child: ClipRRect(
                                                                borderRadius: BorderRadius.circular(28),
                                                                child: Stack(
                                                                        children: [
                                                                                SizedBox(
                                                                                        height: 380,
                                                                                        width: double.infinity,
                                                                                        child: _image(asset, fit: BoxFit.cover),
                                                                                ),
                                                                                Positioned(
                                                                                        right: 14,
                                                                                        bottom: 14,
                                                                                        child: DecoratedBox(
                                                                                                decoration: BoxDecoration(
                                                                                                        color: Colors.black.withValues(alpha: .45),
                                                                                                        borderRadius: BorderRadius.circular(999),
                                                                                                ),
                                                                                                child: const Padding(
                                                                                                        padding: EdgeInsets.all(9),
                                                                                                        child: Icon(Icons.open_in_full_rounded, size: 18, color: Colors.white),
                                                                                                ),
                                                                                        ),
                                                                                ),
                                                                        ],
                                                                ),
                                                        ),
                                                ),
                                        ),
                                        const SizedBox(height: 16),
                                        DecoratedBox(
                                                decoration: StudioVisuals.glass(context, radius: 18),
                                                child: Padding(
                                                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                                                        child: Row(
                                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                                children: [
                                                                        Icon(Icons.format_quote_rounded, size: 20, color: scheme.primary),
                                                                        const SizedBox(width: 10),
                                                                        Expanded(
                                                                                child: Text(
                                                                                        asset.prompt,
                                                                                        maxLines: 3,
                                                                                        overflow: TextOverflow.ellipsis,
                                                                                        style: Theme.of(context).textTheme.bodyMedium,
                                                                                ),
                                                                        ),
                                                                ],
                                                        ),
                                                ),
                                        ),
                                ],
                        ),
                ),
        );
  }

  Widget _gallery() => GalleryView(
    studio: studio,
    imageBuilder: (asset) => Hero(
      tag: _heroTag(asset),
      child: _image(asset, fit: BoxFit.cover),
    ),
    onPreview: _preview,
    onAction: _assetAction,
    onReuse: (prompt, options) {
      _galleryPrompt.text = prompt;
      _guard(() => studio.setImageOptions(options));
    },
  );

  Widget _empty(IconData icon, String label) {
    final agent = _page == 1;
    final lang = s.language;
    final items = agent ? _agentSuggestions : _createSuggestions;
    final controller = agent ? _agentPrompt : _galleryPrompt;
    final heading = agent
        ? (lang == 'zh' ? '开启智能对话' : s.t('agent'))
        : (lang == 'zh' ? '开启灵感创作' : s.t('create'));
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _heroPanel(icon, heading, s.t(label)),
              if (studio.activeConfig.imageModel.isEmpty)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: _settings,
                    icon: const Icon(Icons.settings_outlined),
                    label: Text(s.t('configure')),
                  ),
                ),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, space) {
                  final width = space.maxWidth;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final (index, item) in items.indexed)
                        SizedBox(
                          width: width >= 540 ? (width - 12) / 2 : width,
                          child: _ideaTile(item, index, () {
                            _writePrompt(controller, item.prompt(lang));
                          }),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heroPanel(IconData icon, String title, String hint) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: ColoredBox(
        color: const Color(0xff22213e),
        child: Stack(
          alignment: AlignmentDirectional.centerStart,
          children: [
            Positioned.fill(
              child: Transform.flip(
                flipX: Directionality.of(context) == TextDirection.rtl,
                child: const CustomPaint(painter: _HorizonPainter()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 22),
              child: FractionallySizedBox(
                widthFactor: .68,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 22, color: const Color(0xffffd2ad)),
                    const SizedBox(height: 14),
                    Text(
                      title,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hint,
                      style: const TextStyle(color: Color(0xffe2dbeb)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ideaTile(_InspirationCardData item, int index, VoidCallback onTap) {
    const colors = [
      (Color(0xffefe4ff), Color(0xff61369b)),
      (Color(0xffffe6df), Color(0xff954537)),
      (Color(0xffd8eef3), Color(0xff236976)),
      (Color(0xfff0e6cb), Color(0xff795e2c)),
    ];
    final (paper, ink) = colors[index];
    final scheme = Theme.of(context).colorScheme;
    return StudioSurface(
      radius: 15,
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        leading: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: paper,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(item.icon, color: ink),
        ),
        title: Text(
          item.title(s.language),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          item.desc(s.language),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Icon(Icons.arrow_outward, size: 16, color: scheme.outline),
      ),
    );
  }

  /// The conversation, plus the reply being written while a turn is arriving.
  ///
  /// Laid out as a transcript rather than a chat: the model's answer is plain
  /// text on the page, with no surface of its own, so a long answer reads as
  /// one document instead of a stack of boxes. Only what the user typed keeps
  /// a surface, because that is the one thing here which is not part of the
  /// running document.
  Widget _conversation() {
    final streaming =
        studio.streamingText.isNotEmpty || studio.streamingReasoning.isNotEmpty;
    if (studio.chat.isEmpty && !streaming) {
      return Center(
        key: const ValueKey('agent'),
        child: _empty(Icons.auto_awesome_outlined, 'emptyAgent'),
      );
    }
    final entries = <Widget>[
      for (var i = 0; i < studio.chat.length; i++)
        _entry(studio.chat[i], live: i == studio.chat.length - 1),
      if (streaming)
        _entry(
          ChatEntry(
            'assistant',
            studio.streamingText,
            reasoning: studio.streamingReasoning,
          ),
          streaming: true,
        ),
      if (studio.busy && studio.runningTool != null)
        _runningRow(studio.runningTool!),
    ];
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780),
        child: ListView.builder(
          key: ValueKey('agent-${studio.session}'),
          reverse: true,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          itemCount: entries.length,
          itemBuilder: (context, index) => entries[entries.length - index - 1],
        ),
      ),
    );
  }

  Widget _entry(ChatEntry entry, {bool streaming = false, bool live = false}) {
    if (entry.role == 'tool') return _toolEntry(entry, live: live);
    final user = entry.role == 'user';
    final body = <Widget>[
      if (entry.reasoning.isNotEmpty) _thinking(entry.reasoning),
      if (entry.text.isNotEmpty)
        _text(entry.text, user: user, streaming: streaming),
      if (entry.aborted)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            s.t('stopped'),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
      for (final id in entry.assetIds)
        FutureBuilder<Asset?>(
          future: studio.store.asset(id),
          builder: (context, snapshot) {
            final asset = snapshot.data;
            if (asset == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 10),
              child: GestureDetector(
                onTap: () => _preview(asset),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: user ? 120 : 400),
                    child: _image(asset),
                  ),
                ),
              ),
            );
          },
        ),
    ];
    // A turn that only asked for tools has no prose of its own; its calls show
    // up as the result rows that follow it.
    if (!user && body.isEmpty) return const SizedBox.shrink();
    if (!user) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: body,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: body,
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const _deckTools = {
    'create_deck',
    'add_slide',
    'update_slide',
    'remove_slide',
    'finish_deck',
  };

  /// A tool result is one line, not a message: the model called something and
  /// got an answer, and the transcript should read as the log of that work.
  /// A deck row opens the workspace, where the result actually matters.
  Widget _toolEntry(ChatEntry entry, {bool live = false}) {
    final name = entry.name ?? '';
    final deckTool = _deckTools.contains(name);
    final deck = deckTool ? studio.activeDeck : null;
    final label = name.isEmpty ? s.t('agent') : name;
    final detail = deck != null
        ? deck.title
        : name == 'generate_image'
        ? ''
        : entry.text.trim();
    final theme = Theme.of(context);
    if (name == 'ask_user') {
      final ask = askResult(detail);
      if (live && !studio.busy) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: AskCard(
            question: ask.question,
            options: ask.options,
            onSubmit: _answer,
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.help_outline,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ask.question,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final row = Row(
      children: [
        Icon(
          name == 'generate_image'
              ? Icons.image_outlined
              : deckTool
              ? Icons.slideshow_outlined
              : Icons.build_outlined,
          size: 15,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (detail.isNotEmpty) ...[
          Text(' · ', style: theme.textTheme.labelSmall),
          Expanded(
            child: Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ] else
          const Spacer(),
        if (deck != null)
          Icon(
            Icons.chevron_right_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
      ],
    );
    if (deck == null && entry.assetIds.isEmpty) {
      return Padding(padding: const EdgeInsets.only(bottom: 10), child: row);
    }
    final line = deck == null
        ? row
        : InkWell(
            onTap: () => _deck(deck),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: row,
            ),
          );
    if (entry.assetIds.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: line,
      );
    }
    // A picture belongs to the call that made it: it sits under that call's
    // row the moment it arrives, instead of waiting for the turn to end.
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 6, top: deck == null ? 0 : 4),
            child: line,
          ),
          for (final id in entry.assetIds)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _toolThumb(id),
            ),
        ],
      ),
    );
  }

  Widget _toolThumb(String id) => FutureBuilder<Asset?>(
    future: studio.store.asset(id),
    builder: (context, snapshot) {
      final asset = snapshot.data;
      if (asset == null) return const SizedBox.shrink();
      return GestureDetector(
        onTap: () => _preview(asset),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260, maxWidth: 360),
            child: _image(asset),
          ),
        ),
      );
    },
  );

  /// A call that is still running: the row it will leave behind, plus the
  /// spinner saying why the transcript has not moved yet.
  Widget _runningRow(String name) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        key: const ValueKey('runningTool'),
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            name,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            s.t('working'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  void _deck(Deck deck) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DeckWorkspacePage(studio: studio, deck: deck),
    ),
  );

  /// Every deck in this conversation, newest first. The newest is already the
  /// active one; the list is what lets an older deck be reopened after a later
  /// turn moved the active pointer.
  void _decks() {
    final items = studio.decks.values.toList().reversed.toList();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheet).height * .7,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                s.t('decks'),
                style: Theme.of(sheet).textTheme.titleLarge,
              ),
            ),
            for (final deck in items)
              ListTile(
                leading: const Icon(Icons.slideshow_rounded),
                title: Text(
                  deck.title.trim().isEmpty ? s.t('untitledDeck') : deck.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${deck.slides.length} ${s.t('slidesUnit')}'
                  '${deck.finished ? ' · ${s.t('deckFinished')}' : ''}',
                ),
                selected: deck.id == studio.activeDeck?.id,
                onTap: () {
                  Navigator.pop(sheet);
                  studio.openDeck(deck);
                  _deck(deck);
                },
              ),
            const Divider(height: 8),
            ListTile(
              key: const ValueKey('importDeck'),
              leading: const Icon(Icons.upload_file_rounded),
              title: Text(s.t('importDeck')),
              onTap: () {
                Navigator.pop(sheet);
                _guard(() async {
                  final deck = await studio.importDeck();
                  if (deck != null && mounted) {
                    studio.openDeck(deck);
                    _deck(deck);
                  }
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  /// A finished turn is Markdown; one still arriving is plain text, because
  /// half a table, a formula without its closing `$` or an unfinished code
  /// fence cannot be parsed at all, and re-parsing every frame would only make
  /// the text flicker.
  Widget _text(String text, {required bool user, required bool streaming}) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      height: 1.6,
      color: theme.colorScheme.onSurface,
    );
    if (user || streaming) {
      return SelectableText(text, style: style);
    }
    return SelectionArea(
      child: GptMarkdownTheme(
        gptThemeData: studioMarkdownTheme(theme),
        child: GptMarkdown(
          text,
          style: style,
          textDirection: Directionality.of(context),
          // Models write `$…$`, not the package's `\(…\)`.
          useDollarSignsForLatex: true,
          imageBuilder: _blockedImage,
        ),
      ),
    );
  }

  /// The model's own thinking, folded away so it does not push the answer off
  /// the screen, but one tap away for the models that expose it.
  Widget _thinking(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 12),
      shape: const Border(),
      collapsedShape: const Border(),
      dense: true,
      title: Text(s.t('thinking'), style: Theme.of(context).textTheme.labelSmall),
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SelectableText(
            text,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );

  /// A Markdown image points at a host of the model's choosing, and the default
  /// builder would fetch it — reporting this device to a third party the user
  /// never configured. A reply does not need the picture, so the address is
  /// shown instead of being loaded.
  Widget _blockedImage(
    BuildContext context,
    String imageUrl,
    double? width,
    double? height,
  ) => Text(
    imageUrl,
    style: Theme.of(context).textTheme.bodySmall,
  );

  Widget _composer() {
    final agent = _page == 1;
    final refs = agent ? studio.agentRefs : studio.galleryRefs;
    final controller = agent ? _agentPrompt : _galleryPrompt;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: StudioSurface(
            radius: 18,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedSize(
                    duration: _motion,
                    alignment: AlignmentDirectional.topStart,
                    child: refs.isEmpty
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: SizedBox(
                              height: 76,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: refs.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, i) => _appear(
                                  'ref-${refs[i].id}',
                                  Stack(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: SizedBox(
                                          width: 72,
                                          height: 72,
                                          child: _image(
                                            refs[i],
                                            fit: BoxFit.cover,
                                          ),
                                        ),
                                      ),
                                      PositionedDirectional(
                                        start: 4,
                                        bottom: 4,
                                        child: Badge(label: Text('${i + 1}')),
                                      ),
                                      PositionedDirectional(
                                        end: 0,
                                        top: 0,
                                        child: IconButton.filledTonal(
                                          tooltip: s.t('close'),
                                          visualDensity: VisualDensity.compact,
                                          iconSize: 15,
                                          onPressed: studio.busy
                                              ? null
                                              : () => studio.removeReference(
                                                  agent,
                                                  i,
                                                ),
                                          icon: const Icon(Icons.close),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                  if (agent)
                    AnimatedSize(
                      duration: _motion,
                      alignment: AlignmentDirectional.topStart,
                      child: studio.documents.isEmpty
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (
                                      var i = 0;
                                      i < studio.documents.length;
                                      i++
                                    )
                                      InputChip(
                                        key: ValueKey('imported-$i'),
                                        visualDensity: VisualDensity.compact,
                                        avatar: const Icon(
                                          Icons.description_outlined,
                                          size: 16,
                                        ),
                                        label: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 180,
                                          ),
                                          child: Text(
                                            studio.documents[i].name,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        onDeleted: studio.busy
                                            ? null
                                            : () =>
                                                  studio.removeDocument(i),
                                        deleteIcon: const Icon(
                                          Icons.close,
                                          size: 16,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                    ),
                  // Left-aligned horizontally scrollable model selector pills.
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SizedBox(
                      height: 32,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (agent) ...[
                              _modelButton(true),
                              const SizedBox(width: 6),
                              _videoModelButton(),
                              const SizedBox(width: 6),
                            ],
                            _modelButton(false),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) {
                      final style = styleIn(value.text, studio.customStyles);
                      final palette = _commandPalette(
                        value.text,
                        controller,
                        agent,
                      );
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (agent && studio.queuedCount > 0) _queuedLine(),
                          if (style != null)
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: InputChip(
                                  key: const ValueKey('activeStyle'),
                                  visualDensity: VisualDensity.compact,
                                  avatar: const Icon(
                                    Icons.brush_outlined,
                                    size: 16,
                                  ),
                                  label: Text(_styleName(style)),
                                  onDeleted: () => _writePrompt(
                                    controller,
                                    removeStyle(value.text, style),
                                  ),
                                  deleteIcon: const Icon(Icons.close, size: 16),
                                ),
                              ),
                            ),
                          if (palette != null) palette,
                          TextField(
                            controller: controller,
                            minLines: 1,
                            maxLines: 4,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              hintText: s.t(agent ? 'agentPrompt' : 'prompt'),
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  Row(
                    children: [
                      PopupMenuButton<String>(
                        key: const ValueKey('attach'),
                        tooltip: s.t('attach'),
                        enabled: !studio.busy,
                        icon: Icon(
                          agent
                              ? Icons.attach_file_rounded
                              : Icons.add_photo_alternate_outlined,
                          size: 20,
                        ),
                        onSelected: (choice) => _guard(() async {
                          if (choice == 'files') {
                            await studio.importFiles();
                          } else {
                            await studio.pickReferences(agent);
                          }
                        }),
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'refs',
                            key: const ValueKey('addReferences'),
                            child: ListTile(
                              leading: const Icon(
                                Icons.add_photo_alternate_outlined,
                              ),
                              title: Text(s.t('addReferences')),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          if (agent)
                            PopupMenuItem(
                              value: 'files',
                              key: const ValueKey('importFiles'),
                              child: ListTile(
                                leading: const Icon(Icons.attach_file_rounded),
                                title: Text(s.t('importFiles')),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                        ],
                      ),
                      if (agent)
                        IconButton(
                          key: const ValueKey('agentOptions'),
                          tooltip: s.t('conversationSettings'),
                          visualDensity: VisualDensity.compact,
                          onPressed: studio.busy
                              ? null
                              : () => _guard(() async {
                                  final value = await showAgentOptions(
                                    context,
                                    studio.agentOptions,
                                    studio.config.protocol,
                                  );
                                  if (value != null) {
                                    await studio.setAgentOptions(value);
                                  }
                                }),
                          icon: const Icon(Icons.tune_rounded, size: 20),
                        ),
                      IconButton(
                        key: const ValueKey('imageOptions'),
                        tooltip:
                            '${s.t('imageOptions')} · ${studio.imageOptions.size == 'auto' ? s.t('auto') : ratioOfSize(studio.imageOptions.size) ?? studio.imageOptions.size} · ${studio.imageOptions.count}',
                        visualDensity: VisualDensity.compact,
                        onPressed: studio.busy ? null : _options,
                        icon: const Icon(Icons.aspect_ratio_rounded, size: 20),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        key: const ValueKey('submit'),
                        // An Agent turn can take a message while it runs: the
                        // text waits until the current tool calls are answered
                        // instead of starting a second turn.
                        onPressed: studio.busy && !agent
                            ? null
                            : () => _guard(() async {
                                final text = controller.text;
                                if (agent && studio.busy) {
                                  if (studio.interject(text)) controller.clear();
                                  return;
                                }
                                // A slash command is an action, not a message:
                                // /compact folds the older turns right away
                                // instead of waiting for the token limit.
                                if (agent && text.trim() == '/compact') {
                                  await _compactNow(controller);
                                  return;
                                }
                                await studio.submit(
                                  text,
                                  agent,
                                  studio.imageOptions,
                                  onAccepted: controller.clear,
                                );
                                if (agent) _restoreDraft();
                              }),
                        icon: Icon(
                          agent
                              ? Icons.arrow_upward_rounded
                              : Icons.auto_awesome_rounded,
                        ),
                        label: Text(s.t('create')),
                      ),
                    ],
                  ),
                  if (agent) _usageLine(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// What is waiting for the current tool call to finish. Language-free like
  /// the usage line: a clock, the first message, a count when there are more,
  /// and a cross to drop the queue.
  Widget _queuedLine() {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    final count = studio.queuedCount;
    final preview = studio.queuedPreview ?? '';
    return Padding(
      key: const ValueKey('queuedInterjections'),
      padding: const EdgeInsets.only(bottom: 6, left: 4, right: 4),
      child: Row(
        children: [
          Icon(
            Icons.schedule_rounded,
            size: 13,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              count > 1 ? '$preview  +${count - 1}' : preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          InkWell(
            key: const ValueKey('clearQueued'),
            onTap: studio.clearQueued,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The context budget, always on screen but never loud: one thin line of
  /// numbers under the composer. Nothing here is a word, so it reads the same
  /// in all six languages.
  Widget _usageLine() {
    final theme = Theme.of(context);
    final used = studio.contextTokensUsed;
    final limit = studio.contextTokensLimit;
    final turn = studio.turnUsage;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    return Padding(
      key: const ValueKey('contextUsage'),
      padding: const EdgeInsets.only(top: 6, left: 4),
      child: Row(
        children: [
          Icon(
            Icons.data_usage_rounded,
            size: 11,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 4),
          Text(
            limit > 0
                ? '${_tokenCount(used)} / ${_tokenCount(limit)}'
                : _tokenCount(used),
            style: style,
          ),
          if (turn != null) ...[
            const Spacer(),
            Text(
              '↑ ${_tokenCount(turn.input)}  ↓ ${_tokenCount(turn.output)}',
              style: style,
            ),
          ],
        ],
      ),
    );
  }

  static String _tokenCount(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '$value';
  }

  /// The slash-command list, or null when the text is not a command. `/style`
  /// writes its words into the prompt; `/compact` runs right away, which is
  /// what pressing send with the same line does.
  Widget? _commandPalette(
    String text,
    TextEditingController controller,
    bool agent,
  ) {
    // The command is the line being typed, so a prompt written first stays.
    final tail = text.split('\n').last.trimLeft();
    if (!tail.startsWith('/')) return null;
    final command = tail.substring(1).toLowerCase();
    final entries = <Widget>[];
    if (agent && 'compact'.startsWith(command)) {
      entries.add(
        ListTile(
          key: const ValueKey('compactCommand'),
          dense: true,
          leading: const Icon(Icons.compress_rounded, size: 20),
          title: const Text('/compact'),
          subtitle: Text(s.t('compactCommand')),
          onTap: () => _guard(() => _compactNow(controller)),
        ),
      );
    }
    if (!command.startsWith('style')) {
      if ('style'.startsWith(command)) {
        entries.add(
          ListTile(
            key: const ValueKey('styleCommand'),
            dense: true,
            leading: const Icon(Icons.brush_outlined, size: 20),
            title: const Text('/style'),
            subtitle: Text(s.t('styleCommand')),
            onTap: () => _writePrompt(controller, '/style '),
          ),
        );
      }
    } else {
      final query = command.substring('style'.length).trim();
      for (final style in [...builtInStyles, ...studio.customStyles]) {
        final name = _styleName(style);
        if (query.isNotEmpty &&
            !style.id.contains(query) &&
            !name.toLowerCase().contains(query)) {
          continue;
        }
        entries.add(
          ListTile(
            key: ValueKey('styleOption-${style.id}'),
            dense: true,
            leading: const Icon(Icons.palette_outlined, size: 20),
            title: Text(name),
            subtitle: Text(
              style.words,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _writePrompt(controller, insertStyle(text, style)),
          ),
        );
      }
      entries.add(
        ListTile(
          key: const ValueKey('manageStyles'),
          dense: true,
          leading: const Icon(Icons.edit_outlined, size: 20),
          title: Text(s.t('customStyles')),
          onTap: _manageStyles,
        ),
      );
    }
    if (entries.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        // Material, not a coloured Container: ListTile paints its ink on the
        // nearest Material ancestor, and a decorated box in between hides the
        // splash — a debug assertion that a widget test trips on.
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView(shrinkWrap: true, children: entries),
        ),
      ),
    );
  }

  Future<void> _compactNow(TextEditingController controller) async {
    final result = await studio.compactNow();
    controller.clear();
    if (!mounted) return;
    _notice(
      s.t('compactDone').replaceFirst('%s', '${result.compacted}'),
    );
  }

  /// The answer to an `ask_user` card is the next user message, exactly as if
  /// it had been typed into the composer.
  Future<void> _answer(String text) => _guard(() async {
    await studio.submit(text, true, studio.imageOptions);
    _restoreDraft();
  });

  /// Text queued during a turn that ended by asking a question, failing or
  /// being stopped goes back into the composer instead of being sent.
  void _restoreDraft() {
    final draft = studio.takeDraft();
    if (draft == null || draft.isEmpty) return;
    final current = _agentPrompt.text.trim();
    _writePrompt(_agentPrompt, current.isEmpty ? draft : '$current\n\n$draft');
  }

  String _styleName(ImageStyle style) =>
      style.isBuiltIn ? s.t(style.label) : style.label;

  void _writePrompt(TextEditingController controller, String text) {
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _manageStyles() async {
    await showDialog<List<ImageStyle>>(
      context: context,
      builder: (_) => StyleEditorDialog(
        styles: studio.customStyles,
        onSave: studio.saveStyle,
        onRemove: studio.removeStyle,
      ),
    );
    if (mounted) setState(() {});
  }

  /// The model chips get their own line above the input: one for the model that
  /// answers and, on the Agent page, one for the image model, so a generated
  /// picture can be retargeted without leaving the conversation.
  Widget _modelButton(bool agent) {
    final scheme = Theme.of(context).colorScheme;
    final model = agent
        ? studio.activeConfig.agentModel
        : studio.activeConfig.imageModel;
    return TextButton(
      key: ValueKey(agent ? 'switchAgentModel' : 'switchImageModel'),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        backgroundColor: scheme.surfaceContainer,
        foregroundColor: scheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      onPressed: studio.busy
          ? null
          : () => _guard(() async {
              final model = await showModalBottomSheet<String>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                showDragHandle: true,
                builder: (_) => ModelPicker(studio: studio, agent: agent),
              );
              if (model != null) await studio.switchModel(model, agent: agent);
            }),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            agent ? Icons.forum_outlined : Icons.image_outlined,
            size: 14,
            color: scheme.primary,
          ),
          const SizedBox(width: 5),
          Text(
            model.isEmpty
                ? s.t(agent ? 'agentModel' : 'imageModel')
                : model,
            maxLines: 1,
          ),
          if (MediaQuery.sizeOf(context).width >= 840) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 15,
              color: scheme.outline,
            ),
          ],
        ],
      ),
    );
  }

  /// The video model gets its own button on the Agent page: `generate_video`
  /// is a tool like any other, so the model that renders clips must be visible
  /// without leaving the conversation.
  Widget _videoModelButton() {
    final scheme = Theme.of(context).colorScheme;
    final model = studio.videoModel;
    return TextButton(
      key: const ValueKey('switchVideoModel'),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        backgroundColor: scheme.surfaceContainer,
        foregroundColor: scheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      onPressed: studio.busy
          ? null
          : () => _guard(() async {
              final chosen = await showModalBottomSheet<String>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                showDragHandle: true,
                builder: (_) => ModelPicker(studio: studio, video: true),
              );
              if (chosen != null) await studio.setVideoModel(chosen);
            }),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.movie_creation_outlined,
            size: 14,
            color: scheme.primary,
          ),
          const SizedBox(width: 5),
          Text(model.isEmpty ? s.t('videoModel') : model, maxLines: 1),
          if (MediaQuery.sizeOf(context).width >= 840) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 15,
              color: scheme.outline,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _options() async {
    final value = await showModalBottomSheet<ImageOptions>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ImageOptionsSheet(
        options: studio.imageOptions,
        model: studio.activeConfig.imageModel,
      ),
    );
    if (value != null) await _guard(() => studio.setImageOptions(value));
  }

  Widget _image(Asset asset, {BoxFit fit = BoxFit.contain}) => Image.file(
    File(studio.store.file(asset).path),
    fit: fit,
    cacheWidth: 640,
    errorBuilder: (_, _, _) =>
        const Center(child: Icon(Icons.broken_image_outlined)),
    frameBuilder: (context, child, frame, synchronous) => AnimatedOpacity(
      opacity: frame == null && !synchronous ? 0 : 1,
      duration: MediaQuery.of(context).disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 180),
      child: child,
    ),
  );

  Future<void> _assetAction(String action, Asset asset) async {
    if (action == 'reuse') {
      _galleryPrompt.text = asset.prompt;
      _switch(0);
      await _guard(
        () => studio.setImageOptions(ImageOptions.fromJson(asset.parameters)),
      );
    } else if (action == 'save') {
      await _guard(() async {
        await studio.export(asset);
        if (mounted) _notice(s.t('saved'));
      });
    } else if (action == 'delete') {
      if (studio.busy) {
        _notice(s.t('deleteWhileBusy'));
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(s.t('deleteImage')),
          content: Text(s.t('deleteImageConfirm')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(s.t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(s.t('delete')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await _guard(() => studio.deleteAsset(asset));
    } else {
      studio.useReference(asset, action == 'agent');
      _switch(action == 'agent' ? 1 : 0);
    }
  }

  void _preview(Asset asset) => showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: IconButton(
                tooltip: s.t('close'),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            Flexible(
              child: InteractiveViewer(
                minScale: .5,
                maxScale: 5,
                child: Hero(
                  tag: _heroTag(asset),
                  child: Image.file(
                    studio.store.file(asset),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 12,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _assetAction('save', asset);
                    },
                    icon: const Icon(Icons.download_outlined),
                    label: Text(s.t('saveImage')),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _assetAction('edit', asset);
                    },
                    child: Text(s.t('edit')),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _assetAction('agent', asset);
                    },
                    child: Text(s.t('continueAgent')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _confirmDelete(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('deleteConversation')),
        content: Text(s.t('deleteConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.t('delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Close the list first: the conversation it was listing no longer exists.
    Navigator.pop(context);
    await _guard(() => studio.deleteConversation(id));
  }

  Future<void> _history() async {
    final sessions = await studio.conversations();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .6,
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  s.t('history'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final session in sessions)
                FutureBuilder<List<ChatEntry>>(
                  future: studio.store.messages(session['session'] as String),
                  builder: (context, snapshot) {
                    final entries = snapshot.data;
                    return ListTile(
                      leading: const Icon(Icons.chat_bubble_outline_rounded),
                      title: Text(
                        entries == null || entries.isEmpty
                            ? '…'
                            : entries.first.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: s.t('deleteConversation'),
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: studio.busy
                            ? null
                            : () => _confirmDelete(session['session'] as String),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _guard(
                          () => studio.switchConversation(
                            session['session'] as String,
                          ),
                        );
                      },
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 以固定画布绘制暮色山脊，缩放时保留海报的分层构图。
class _HorizonPainter extends CustomPainter {
  const _HorizonPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xff22213e), Color(0xff514477), Color(0xffc9879a)],
          stops: [0, .55, 1],
        ).createShader(bounds),
    );
    // 按高度等比缩放，让窄屏上的落日保持圆形。
    canvas.save();
    canvas.translate(size.width, 0);
    canvas.scale(size.height / 180);
    final paint = Paint()..color = const Color(0xffffd7a3);
    canvas.drawCircle(const Offset(-78, 64), 34, paint);
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..color = const Color(0x77ffdfb7);
    canvas.drawCircle(const Offset(-78, 64), 42, paint);
    paint.style = PaintingStyle.fill;
    for (final (offset, color) in const [
      (0.0, Color(0xffaa87a7)),
      (25.0, Color(0xff836d98)),
      (52.0, Color(0xff554d77)),
      (77.0, Color(0xff373754)),
    ]) {
      final ridge = Path()
        ..moveTo(-420 + offset, 183)
        ..cubicTo(-300, 153, -272, 102 + offset, -220, 117 + offset)
        ..cubicTo(-150, 145 + offset, -122, 50 + offset, -70, 85 + offset)
        ..quadraticBezierTo(-38, 109 + offset, 0, 68 + offset)
        ..lineTo(0, 183)
        ..close();
      canvas.drawPath(ridge, paint..color = color);
    }
    canvas.restore();
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xff22213e), Color(0xee22213e), Color(0x0022213e)],
          stops: [0, .38, .79],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(_HorizonPainter oldDelegate) => false;
}

class _InspirationCardData {
  const _InspirationCardData({
    required this.icon,
    required this.titleZh,
    required this.titleEn,
    required this.descZh,
    required this.descEn,
    required this.promptZh,
    required this.promptEn,
  });

  final IconData icon;
  final String titleZh;
  final String titleEn;
  final String descZh;
  final String descEn;
  final String promptZh;
  final String promptEn;

  String title(String lang) => lang == 'zh' ? titleZh : titleEn;
  String desc(String lang) => lang == 'zh' ? descZh : descEn;
  String prompt(String lang) => lang == 'zh' ? promptZh : promptEn;
}

const _createSuggestions = [
  _InspirationCardData(
    icon: Icons.nightlife_rounded,
    titleZh: '赛博朋克雨夜',
    titleEn: 'Cyberpunk Neon',
    descZh: '雨夜街道、全息霓虹与光影倒影',
    descEn: 'Rainy streets, neon reflections & holograms',
    promptZh:
        '雨夜中的赛博朋克未来城市街道，湿漉漉的地面映照着斑斓的霓虹灯光与巨大全息广告牌，高耸入云的摩天大楼，电影感宽银幕构图，8K极致细节',
    promptEn:
        'Futuristic cyberpunk city street at rainy night, wet asphalt with vibrant neon reflections, massive holograms, towering megastructures, cinematic atmosphere, 8k',
  ),
  _InspirationCardData(
    icon: Icons.palette_outlined,
    titleZh: '唯美水彩插画',
    titleEn: 'Dreamy Watercolor',
    descZh: '日系清透水彩、樱花飞舞与微风',
    descEn: 'Ethereal anime watercolor with cherry blossoms',
    promptZh:
        '温暖阳光下的日系治愈水彩画，微风吹拂的樱花树下的小电车站，清澈明亮的天空与白云，通透细腻的笔触，新海诚唯美光影',
    promptEn:
        'Healing Japanese watercolor illustration, train station under blooming cherry blossoms, gentle breeze, clear blue sky and fluffy clouds, Makoto Shinkai lighting style',
  ),
  _InspirationCardData(
    icon: Icons.rocket_launch_outlined,
    titleZh: '深空星际漫游',
    titleEn: 'Deep Space Odyssey',
    descZh: '穿梭土星环的宏伟探险飞船',
    descEn: 'Exploration starship cruising through planetary rings',
    promptZh:
        '史诗级深空科幻场景，穿行在土星巨大冰环带之上的探险星际飞船，远方瑰丽的星云与恒星光晕，硬核机械细节，克里斯托弗·诺兰电影质感',
    promptEn:
        'Epic deep space sci-fi scene, massive interstellar exploration vessel flying through Saturn rings, distant colorful nebula, hard sci-fi realism, cinematic lighting',
  ),
  _InspirationCardData(
    icon: Icons.apartment_rounded,
    titleZh: '极简几何建筑',
    titleEn: 'Modern Architecture',
    descZh: '清水混凝土、自然天光与温润橡木',
    descEn: 'Concrete, oak & dramatic natural light',
    promptZh:
        '现代极简主义建筑内部空间，清水混凝土墙面与温润原木材质，午后阳光斜射穿过落地玻璃窗留下的几何光影，安藤忠雄极简宁静禅意风格',
    promptEn:
        'Minimalist architectural interior, fair-faced concrete and warm oak wood, dramatic geometric afternoon sunlight through floor-to-ceiling windows, serene Tadao Ando aesthetic',
  ),
];

const _agentSuggestions = [
  _InspirationCardData(
    icon: Icons.lightbulb_outlined,
    titleZh: '创意构思企划',
    titleEn: 'Concept Brainstorm',
    descZh: '构思赛博朋克科幻世界观与主角设定',
    descEn: 'Sci-fi worldbuilding & character lore',
    promptZh:
        '帮我构思一个近未来赛博朋克侦探故事的世界观背景与主角设定，包括核心冲突和代表性视觉元素。',
    promptEn:
        'Brainstorm a gritty near-future cyberpunk detective story setting, main character lore, and key visual aesthetics.',
  ),
  _InspirationCardData(
    icon: Icons.auto_awesome_mosaic_outlined,
    titleZh: '视觉图像方案',
    titleEn: 'Image Concept Set',
    descZh: '深海探索科技公司品牌视觉方案',
    descEn: 'Visual prompts for deep-sea tech brand',
    promptZh:
        '为一家专注于深海探索的科技公司设计 3 组具有未来感和科技感的品牌视觉图像构思与提示词。',
    promptEn:
        'Design 3 futuristic brand visual concepts and generation prompts for a deep-sea exploration technology company.',
  ),
  _InspirationCardData(
    icon: Icons.terminal_rounded,
    titleZh: '技术架构设计',
    titleEn: 'Architecture & Code',
    descZh: '设计高并发缓存与消息队列容灾策略',
    descEn: 'Resilient caching & message queue strategies',
    promptZh:
        '请帮我梳理一套高性能分布式系统的缓存与消息队列设计方案，并分析关键容灾策略。',
    promptEn:
        'Help me design a resilient caching and message queue strategy for high-throughput distributed architectures.',
  ),
  _InspirationCardData(
    icon: Icons.slideshow_rounded,
    titleZh: '演示文稿策划',
    titleEn: 'Presentation Deck',
    descZh: '制作 AI 创作工具产品发布会 10 页演讲大纲',
    descEn: '10-slide keynote outline for product launch',
    promptZh:
        '为一款全新 AI 创作工具的产品发布会制作一份 10 页 PPT 演讲大纲，结构清晰并突出核心亮点。',
    promptEn:
        'Create a structured 10-slide keynote presentation deck outline for an innovative AI creator studio launch.',
  ),
];
