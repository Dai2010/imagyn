import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/studio.dart';
import '../l10n/strings.dart';

class GalleryView extends StatefulWidget {
  const GalleryView({
    super.key,
    required this.studio,
    required this.imageBuilder,
    required this.onPreview,
    required this.onAction,
    required this.onReuse,
  });
  final Studio studio;
  final Widget Function(Asset) imageBuilder;
  final ValueChanged<Asset> onPreview;
  final void Function(String, Asset) onAction;
  final void Function(String, ImageOptions) onReuse;
  @override
  State<GalleryView> createState() => _GalleryViewState();
}

class _GalleryViewState extends State<GalleryView> {
  final search = TextEditingController();
  bool favoritesOnly = false;
  String filter = 'all';
  Studio get studio => widget.studio;
  Strings get s => Strings.of(context);
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  bool _matches(String prompt, String model) {
    final query = search.text.trim().toLowerCase();
    return '$prompt $model'.toLowerCase().contains(query);
  }

  @override
  Widget build(BuildContext context) {
    final assets = studio.gallery
        .where(
          (a) =>
              (filter == 'all' || filter == 'complete') &&
              (!favoritesOnly || studio.favorites.contains(a.id)) &&
              _matches(a.prompt, '${a.parameters['model'] ?? ''}'),
        )
        .toList();
    final jobs = favoritesOnly
        ? <ImageJob>[]
        : studio.jobs
              .where(
                (j) =>
                    (filter == 'all' || filter == j.state) &&
                    _matches(j.prompt, '${j.record['model'] ?? ''}'),
              )
              .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              IconButton.filledTonal(
                tooltip: s.t('favorites'),
                isSelected: favoritesOnly,
                onPressed: () => setState(() => favoritesOnly = !favoritesOnly),
                icon: Icon(
                  favoritesOnly
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                ),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                tooltip: s.t('filter'),
                initialValue: filter,
                onSelected: (v) => setState(() => filter = v),
                itemBuilder: (_) =>
                    ['all', 'complete', 'submitting', 'failed', 'unknown']
                        .map(
                          (v) => PopupMenuItem(
                            value: v,
                            child: Text(
                              s.t(v == 'unknown' ? 'interrupted' : v),
                            ),
                          ),
                        )
                        .toList(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Text(s.t(filter == 'unknown' ? 'interrupted' : filter)),
                      const Icon(Icons.expand_more, size: 18),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: s.t('searchGallery'),
                    prefixIcon: const Icon(Icons.search_rounded),
                    isDense: true,
                    suffixIcon: search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: s.t('close'),
                            onPressed: () => setState(search.clear),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: assets.isEmpty && jobs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.photo_library_outlined,
                          size: 48,
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          s.t(
                            studio.gallery.isEmpty && studio.jobs.isEmpty
                                ? 'emptyGallery'
                                : 'noMatches',
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 1050
                        ? 3
                        : constraints.maxWidth >= 700
                        ? 2
                        : 1;
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: 200,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                      ),
                      itemCount: jobs.length + assets.length,
                      itemBuilder: (_, index) => index < jobs.length
                          ? _job(jobs[index])
                          : _asset(assets[index - jobs.length]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _frame(Widget image, Widget details, {VoidCallback? onTap}) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: BorderSide(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .5),
      ),
    ),
    child: InkWell(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 5, child: image),
          Expanded(
            flex: 6,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 4, 4),
              child: details,
            ),
          ),
        ],
      ),
    ),
  );

  /// What was asked for, and what actually came back when the two differ. That
  /// difference is the only way to see a service ignoring the requested size,
  /// so it is shown rather than hidden behind the requested value.
  String _assetSize(Asset asset) {
    final s = Strings.of(context);
    String label(String value) =>
        value == 'auto' ? s.t('auto') : ratioOfSize(value) ?? value;
    final requested = asset.parameters['size'] as String?;
    final actual = asset.parameters['actualSize'] as String?;
    if (requested == null) return actual == null ? '' : label(actual);
    if (actual == null || actual == requested) return label(requested);
    return '${label(requested)} → ${label(actual)}';
  }

  Widget _asset(Asset asset) => _frame(
    Stack(
      fit: StackFit.expand,
      children: [
        widget.imageBuilder(asset),
        if (asset.parameters['size'] != null ||
            asset.parameters['actualSize'] != null)
          PositionedDirectional(
            start: 8,
            top: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Text(
                  _assetSize(asset),
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
          ),
      ],
    ),
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            asset.prompt,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (asset.parameters['model'] != null)
          Text(
            '${asset.parameters['model']}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              tooltip: s.t('favorites'),
              visualDensity: VisualDensity.compact,
              onPressed: () => studio.toggleFavorite(asset),
              icon: Icon(
                studio.favorites.contains(asset.id)
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
                size: 20,
              ),
            ),
            PopupMenuButton<String>(
              tooltip: s.t('more'),
              onSelected: (v) => widget.onAction(v, asset),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'reuse', child: Text(s.t('reusePrompt'))),
                PopupMenuItem(value: 'save', child: Text(s.t('saveImage'))),
                PopupMenuItem(value: 'edit', child: Text(s.t('edit'))),
                PopupMenuItem(
                  value: 'agent',
                  child: Text(s.t('continueAgent')),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
    onTap: () => widget.onPreview(asset),
  );

  Widget _job(ImageJob job) {
    final running = job.state == 'submitting';
    return _frame(
      Center(
        child: running
            ? const CircularProgressIndicator()
            : Icon(
                job.state == 'unknown'
                    ? Icons.help_outline_rounded
                    : Icons.error_outline_rounded,
                size: 40,
              ),
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.t(
              running
                  ? 'working'
                  : job.state == 'unknown'
                  ? 'interrupted'
                  : 'failed',
            ),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Text(
              job.prompt,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (!running)
                TextButton(
                  onPressed: () => _jobDetails(job),
                  child: Text(s.t('details')),
                ),
              if (running)
                TextButton(
                  onPressed: studio.cancel,
                  child: Text(s.t('cancel')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _jobDetails(ImageJob job) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .8,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.t(job.state == 'unknown' ? 'interrupted' : 'failed'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            SelectableText(job.prompt),
            const SizedBox(height: 12),
            Text(
              '${job.record['model'] ?? ''} · ${job.options.size} · ${job.options.format.toUpperCase()}',
            ),
            if (job.record['createdAt'] != null)
              Text('${job.record['createdAt']}'),
            const SizedBox(height: 12),
            Text(
              s.t(
                job.state == 'unknown'
                    ? 'unknown'
                    : job.record['error'] as String? ?? 'error',
              ),
            ),
            if (job.record['detail'] != null)
              SelectableText('${job.record['detail']}'),
            const SizedBox(height: 20),
            if ((job.record['outputs'] as List?)?.isNotEmpty == true) ...[
              FilledButton.icon(
                onPressed: studio.busy
                    ? null
                    : () {
                        Navigator.pop(context);
                        studio.retryDownload(job);
                      },
                icon: const Icon(Icons.download_rounded),
                label: Text(s.t('retryDownload')),
              ),
              const SizedBox(height: 8),
            ] else if (job.prompt.trim().isNotEmpty) ...[
              // Nothing ever came back from the service, so the work itself is
              // what gets repeated, from the prompt and references it recorded.
              FilledButton.icon(
                onPressed: studio.busy
                    ? null
                    : () {
                        Navigator.pop(context);
                        studio.retryJob(job);
                      },
                icon: const Icon(Icons.refresh_rounded),
                label: Text(s.t('retryGenerate')),
              ),
              const SizedBox(height: 8),
            ],
            FilledButton(
              onPressed: studio.busy
                  ? null
                  : () {
                      widget.onReuse(job.prompt, job.options);
                      Navigator.pop(context);
                    },
              child: Text(s.t('reusePrompt')),
            ),
            TextButton(
              onPressed: () {
                studio.dismissJob(job);
                Navigator.pop(context);
              },
              child: Text(s.t('dismiss')),
            ),
          ],
        ),
      ),
    ),
  );
}
