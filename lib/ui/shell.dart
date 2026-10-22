import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../core/models.dart';
import '../core/studio.dart';
import '../l10n/strings.dart';
import 'settings.dart';
import 'gallery.dart';
import 'image_options.dart';
import 'agent_options.dart';
import 'model_picker.dart';
import 'deck_workspace.dart';

class StudioShell extends StatefulWidget {
  const StudioShell({super.key, required this.studio});
  final Studio studio;
  @override
  State<StudioShell> createState() => _StudioShellState();
}

class _StudioShellState extends State<StudioShell> {
  int _page = 0;

  /// Which way the last page change went, so the two pages slide apart in the
  /// direction the user moved instead of cross-fading in place.
  bool _forward = true;
  final _galleryPrompt = TextEditingController();
  final _agentPrompt = TextEditingController();

  Studio get studio => widget.studio;
  Strings get s => Strings.of(context);

  /// Every animation in this screen collapses to nothing when the user asked
  /// for less motion in Settings.
  Duration get _motion => MediaQuery.of(context).disableAnimations
      ? Duration.zero
      : const Duration(milliseconds: 220);

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
    _forward = page > _page;
    _page = page;
  });

  Widget _pageTransition(Widget child, Animation<double> animation) {
    final incoming = child.key == ValueKey(_page);
    final slide = (_forward ? 1.0 : -1.0) * (incoming ? 1 : -1) * .04;
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(
          begin: Offset(slide, 0),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
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
    final wide = MediaQuery.sizeOf(context).width >= 760;
    if (studio.onboarding) return _welcome();
    final title = _page == 0 ? s.t('gallery') : s.t('agent');
    final content = Column(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: _motion,
            transitionBuilder: _pageTransition,
            child: KeyedSubtree(
              key: ValueKey(_page),
              child: _page == 0 ? _gallery() : _conversation(),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.t(studio.error!),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      if (studio.errorDetail != null)
                        SelectableText(
                          studio.errorDetail!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
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
                )
              : const SizedBox.shrink(),
        ),
        _composer(),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          if (studio.decks.isNotEmpty)
            IconButton(
              key: const ValueKey('deckList'),
              tooltip: s.t('decks'),
              onPressed: () => _decks(),
              icon: const Icon(Icons.slideshow_rounded),
            ),
          if (_page == 1) ...[
            IconButton(
              tooltip: s.t('history'),
              onPressed: studio.busy ? null : _history,
              icon: const Icon(Icons.history_rounded),
            ),
            IconButton(
              tooltip: s.t('newChat'),
              onPressed: studio.busy
                  ? null
                  : () => _guard(studio.newConversation),
              icon: const Icon(Icons.add_comment_outlined),
            ),
          ],
          if (!wide)
            IconButton(
              tooltip: s.t('settings'),
              onPressed: studio.busy ? null : _settings,
              icon: const Icon(Icons.settings_outlined),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: wide,
        child: wide
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: _page,
                    onDestinationSelected: _switch,
                    labelType: NavigationRailLabelType.all,
                    leading: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.auto_awesome_rounded, size: 28),
                    ),
                    trailing: Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: IconButton(
                            tooltip: s.t('settings'),
                            onPressed: studio.busy ? null : _settings,
                            icon: const Icon(Icons.settings_outlined),
                          ),
                        ),
                      ),
                    ),
                    destinations: [
                      NavigationRailDestination(
                        icon: const Icon(Icons.grid_view_outlined),
                        selectedIcon: const Icon(Icons.grid_view_rounded),
                        label: Text(s.t('gallery')),
                      ),
                      NavigationRailDestination(
                        icon: const Icon(Icons.forum_outlined),
                        selectedIcon: const Icon(Icons.forum_rounded),
                        label: Text(s.t('agent')),
                      ),
                    ],
                  ),
                  Expanded(child: content),
                ],
              )
            : content,
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _page,
              onDestinationSelected: _switch,
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.grid_view_outlined),
                  selectedIcon: const Icon(Icons.grid_view_rounded),
                  label: s.t('gallery'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.forum_outlined),
                  selectedIcon: const Icon(Icons.forum_rounded),
                  label: s.t('agent'),
                ),
              ],
            ),
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

  Widget _empty(IconData icon, String label) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 54,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        const SizedBox(height: 18),
        Text(
          s.t(label),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (studio.activeConfig.imageModel.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: TextButton(
              onPressed: _settings,
              child: Text(s.t('configure')),
            ),
          ),
      ],
    ),
  );

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
      for (final entry in studio.chat) _entry(entry),
      if (streaming)
        _entry(
          ChatEntry(
            'assistant',
            studio.streamingText,
            reasoning: studio.streamingReasoning,
          ),
          streaming: true,
        ),
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

  Widget _entry(ChatEntry entry, {bool streaming = false}) {
    if (entry.role == 'tool') return _toolEntry(entry);
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
  Widget _toolEntry(ChatEntry entry) {
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
      final question = detail
          .replaceFirst('Question for the user: ', '')
          .split(' The turn ends here;')
          .first;
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
                    question,
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
    if (deck == null) {
      return Padding(padding: const EdgeInsets.only(bottom: 10), child: row);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => _deck(deck),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: row,
        ),
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
    final style = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(height: 1.6);
    if (user || streaming) {
      return SelectableText(text, style: style);
    }
    return SelectionArea(
      child: GptMarkdown(
        text,
        style: style,
        textDirection: Directionality.of(context),
        // Models write `$…$`, not the package's `\(…\)`.
        useDollarSignsForLatex: true,
        imageBuilder: _blockedImage,
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
        constraints: const BoxConstraints(maxWidth: 980),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: .5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSize(
                    duration: _motion,
                    alignment: AlignmentDirectional.topStart,
                    child: refs.isEmpty
                        ? const SizedBox.shrink()
                        : SizedBox(
                            height: 80,
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
                                      borderRadius: BorderRadius.circular(12),
                                      child: SizedBox(
                                        width: 76,
                                        height: 76,
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
                                        iconSize: 16,
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
                  // The two models get their own line: sharing the action row
                  // with four icons squeezed the name down to "de…", and the
                  // Agent page lost the image model entirely.
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Wrap(
                        spacing: 4,
                        children: [
                          if (agent) _modelButton(true),
                          _modelButton(false),
                        ],
                      ),
                    ),
                  ),
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
                  Row(
                    children: [
                      if (agent)
                        IconButton(
                          key: const ValueKey('importFiles'),
                          tooltip: s.t('importFiles'),
                          visualDensity: VisualDensity.compact,
                          onPressed: studio.busy
                              ? null
                              : () => _guard(studio.importFiles),
                          icon: const Icon(Icons.attach_file_rounded, size: 20),
                        ),
                      IconButton(
                        tooltip: s.t('addReferences'),
                        visualDensity: VisualDensity.compact,
                        onPressed: studio.busy
                            ? null
                            : () => _guard(() => studio.pickReferences(agent)),
                        icon: const Icon(Icons.add_photo_alternate_outlined),
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
                        onPressed: studio.busy
                            ? null
                            : () => _guard(() async {
                                final text = controller.text;
                                // A slash command is an action, not a message:
                                // /compact folds the older turns right away
                                // instead of waiting for the token limit.
                                if (agent && text.trim() == '/compact') {
                                  final result = await studio.compactNow();
                                  controller.clear();
                                  _notice(
                                    s.t('compactDone').replaceFirst(
                                      '%s',
                                      '${result.compacted}',
                                    ),
                                  );
                                  return;
                                }
                                await studio.submit(
                                  text,
                                  agent,
                                  studio.imageOptions,
                                  onAccepted: controller.clear,
                                );
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The model chips get their own line above the input: one for the model that
  /// answers and, on the Agent page, one for the image model, so a generated
  /// picture can be retargeted without leaving the conversation.
  Widget _modelButton(bool agent) {
    final model = agent
        ? studio.activeConfig.agentModel
        : studio.activeConfig.imageModel;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 160),
      child: TextButton(
        key: ValueKey(agent ? 'switchAgentModel' : 'switchImageModel'),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 36),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
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
            Icon(agent ? Icons.forum_outlined : Icons.image_outlined, size: 16),
            const SizedBox(width: 6),
            // A bounded width is what keeps a long model id readable: inside an
            // unbounded Row the ellipsis collapsed the label to two letters.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                model.isEmpty
                    ? s.t(agent ? 'agentModel' : 'imageModel')
                    : model,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
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
        styles: studio.customStyles,
        onSaveStyle: studio.saveStyle,
        onRemoveStyle: studio.removeStyle,
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
