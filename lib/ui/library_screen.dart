import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'libraries_screen.dart';
import 'theme.dart';
import 'widgets.dart';

enum _Tab { browse, artists, collections, folders }

/// One library: a paged grid with sorting and an unwatched filter, plus
/// collections and the raw folder tree.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key, required this.libraryRef});
  final LibraryRef libraryRef;

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  static const _pageSize = 60;
  final _scroll = ScrollController();
  final _items = <MediaItem>[];
  LibraryQuery _query = const LibraryQuery();
  _Tab _tab = _Tab.browse;
  Library? _library;
  int _total = 0;
  bool _loading = false;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 900) _loadMore();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool get _done => _library != null && _items.length >= _total;

  Future<void> _reload() async {
    _generation++;
    setState(() {
      _items.clear();
      _total = 0;
      _error = null;
      _loading = false;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || (_done && _items.isNotEmpty) || _error != null) return;
    if (_tab == _Tab.collections || _tab == _Tab.folders) return;
    final gen = _generation;
    setState(() => _loading = true);
    try {
      final Library lib = _library ??
          await ref.read(libraryProvider(widget.libraryRef).future);
      _library = lib;
      final page = await ref
          .read(backendsProvider)[lib.serverId]!
          .libraryItems(lib,
              start: _items.length, limit: _pageSize, query: _query);
      if (!mounted || gen != _generation) return;
      setState(() {
        _items.addAll(page.items);
        // An empty page ends paging even if the server's total was off.
        _total = page.items.isEmpty ? _items.length : page.total;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _setQuery(LibraryQuery q) {
    if (q == _query) return;
    _query = q;
    _reload();
  }

  void _setTab(_Tab t) {
    if (t == _tab) return;
    _tab = t;
    _query = _query.copyWith(
        view: t == _Tab.artists ? LibraryView.artists : LibraryView.items);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLayout.of(context);
    final lib = _library ??
        ref.watch(libraryProvider(widget.libraryRef)).value;
    final kind = lib?.kind ?? LibraryKind.other;
    final tabs = <(_Tab, String)>[
      (_Tab.browse, kind == LibraryKind.music ? 'Albums' : 'All'),
      if (kind == LibraryKind.music) (_Tab.artists, 'Artists'),
      if (kind != LibraryKind.other) (_Tab.collections, 'Collections'),
      if (kind != LibraryKind.other) (_Tab.folders, 'Folders'),
    ];
    final paged = _tab == _Tab.browse || _tab == _Tab.artists;

    return Scaffold(
      appBar: AppBar(
        leading: const Padding(
            padding: EdgeInsets.only(left: 8), child: BackOrHome()),
        title: Text(lib?.title ?? ''),
        actions: [
          if (paged && _total > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text('$_total',
                    style: const TextStyle(color: Palette.muted)),
              ),
            ),
        ],
      ),
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.fromLTRB(l.gutter, 4, l.gutter, 4),
              child: Row(
                children: [
                  for (final (tab, label) in tabs) ...[
                    ChoiceChip(
                      label: Text(label),
                      selected: _tab == tab,
                      onSelected: (_) => _setTab(tab),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (paged) ...[
                    const SizedBox(width: 8),
                    _SortButton(query: _query, onChanged: _setQuery),
                    if (kind == LibraryKind.movies ||
                        kind == LibraryKind.shows) ...[
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Unwatched'),
                        selected: _query.unwatchedOnly,
                        onSelected: (v) =>
                            _setQuery(_query.copyWith(unwatchedOnly: v)),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          if (_tab == _Tab.collections)
            _ProviderGrid(
              value: ref.watch(libraryCollectionsProvider(widget.libraryRef)),
              empty: 'No collections in this library',
            )
          else if (_tab == _Tab.folders)
            _ProviderGrid(
              value: ref.watch(libraryFoldersProvider(widget.libraryRef)),
              empty: 'This library has no folders to browse',
            )
          else if (_error != null && _items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: MessageView.error(_error!, onRetry: _reload),
            )
          else if (_items.isEmpty && !_loading && _library != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: MessageView(
                icon: Icons.inbox_outlined,
                title: _query.unwatchedOnly
                    ? 'All caught up'
                    : 'Nothing here yet',
                body: _query.unwatchedOnly
                    ? 'Everything in this library has been watched.'
                    : null,
              ),
            )
          else ...[
            MediaSliverGrid(items: _items, autofocusFirst: l.tv),
            if (_loading)
              const SliverToBoxAdapter(
                child: Padding(padding: EdgeInsets.all(24), child: Loading()),
              ),
          ],
        ],
      ),
    );
  }
}

class _ProviderGrid extends StatelessWidget {
  const _ProviderGrid({required this.value, required this.empty});
  final AsyncValue<List<MediaItem>> value;
  final String empty;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => const SliverFillRemaining(
          hasScrollBody: false, child: Loading()),
      error: (e, _) => SliverFillRemaining(
          hasScrollBody: false, child: MessageView.error(e)),
      data: (items) => items.isEmpty
          ? SliverFillRemaining(
              hasScrollBody: false,
              child: MessageView(icon: Icons.inbox_outlined, title: empty),
            )
          : MediaSliverGrid(items: items),
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.query, required this.onChanged});
  final LibraryQuery query;
  final ValueChanged<LibraryQuery> onChanged;

  @override
  Widget build(BuildContext context) {
    return SelectMenu(
      items: [
        for (final f in SortField.values)
          SelectMenuItem(
            label: f.label,
            selected: query.sort == f,
            icon: query.sort == f
                ? (query.descending
                    ? Icons.arrow_downward_rounded
                    : Icons.arrow_upward_rounded)
                : null,
            // Picking the current field flips direction; a new field starts
            // with the direction that makes sense for it.
            onPressed: () => onChanged(query.copyWith(
              sort: f,
              descending:
                  query.sort == f ? !query.descending : f != SortField.title,
            )),
          ),
      ],
      builder: (context, focusNode, toggle) => ActionChip(
        focusNode: focusNode,
        avatar: const Icon(Icons.sort_rounded, size: 18),
        label: Text(query.sort.label),
        onPressed: toggle,
      ),
    );
  }
}
