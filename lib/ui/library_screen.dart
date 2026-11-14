import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'libraries_screen.dart';
import 'phone_input.dart';
import 'theme.dart';
import 'widgets.dart';

enum _Tab { recommended, browse, artists, collections, folders }

bool _isVideo(LibraryKind k) =>
    k == LibraryKind.movies || k == LibraryKind.shows;

/// One library: Recommended rows (movies and TV, the default there), a paged
/// grid with sorting and an unwatched filter, collections and the raw folder
/// tree.
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
  /// Each library's sort and filters, kept while the app runs.
  /// (Without the view: the tab decides that, so a remembered Artists
  /// view can't open under the Albums tab.)
  static final _remembered = <LibraryRef, LibraryQuery>{};
  late LibraryQuery _query =
      _remembered[widget.libraryRef] ?? const LibraryQuery();
  final _filterButton = FocusNode(debugLabel: 'filter button');
  /// The tab the user picked; until then, the library kind decides.
  _Tab? _picked;
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
    _filterButton.dispose();
    super.dispose();
  }

  _Tab _tabFor(LibraryKind? kind) =>
      _picked ??
      (kind != null && _isVideo(kind) ? _Tab.recommended : _Tab.browse);

  _Tab get _tab => _tabFor(_library?.kind);

  bool get _paged => _tab == _Tab.browse || _tab == _Tab.artists;

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
    final gen = _generation;
    setState(() => _loading = true);
    try {
      final Library lib = _library ??
          await ref.read(libraryProvider(widget.libraryRef).future);
      _library = lib;
      // The other tabs come from providers; only the grid pages by hand.
      if (!_paged) {
        if (mounted) setState(() => _loading = false);
        return;
      }
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
    _remembered[widget.libraryRef] = q.copyWith(view: LibraryView.items);
    _reload();
  }

  /// After a chip goes (OK on it with the remote), land on Filter rather
  /// than lose focus or jump to the first card.
  void _focusFilterButton() => WidgetsBinding.instance
      .addPostFrameCallback((_) => _filterButton.requestFocus());

  void _removeFilter(String category, FilterValue value) {
    final filters = {
      for (final e in _query.filters.entries)
        e.key: e.key == category
            ? [for (final v in e.value) if (v != value) v]
            : e.value,
    }..removeWhere((_, v) => v.isEmpty);
    setState(() {});
    _setQuery(_query.copyWith(filters: filters));
    _focusFilterButton();
  }

  Future<void> _openFilters(Library library, List<FilterCategory> cats) =>
      showPanel<void>(
        context,
        width: 440,
        builder: (_) => _FilterPanel(
          library: library,
          categories: cats,
          query: _query,
          onChanged: (q) {
            if (mounted) setState(() {});
            _setQuery(q);
          },
        ),
      );

  void _setTab(_Tab t) {
    if (t == _tab) return;
    _picked = t;
    _query = _query.copyWith(
        view: t == _Tab.artists ? LibraryView.artists : LibraryView.items);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    // Something was deleted: the hand-paged grid starts over.
    ref.listen(contentRevisionProvider, (_, _) => _reload());
    final l = AppLayout.of(context);
    final lib = _library ??
        ref.watch(libraryProvider(widget.libraryRef)).value;
    final kind = lib?.kind ?? LibraryKind.other;
    final tab = _tabFor(lib?.kind);
    final tabs = <(_Tab, String)>[
      if (_isVideo(kind)) (_Tab.recommended, 'Recommended'),
      (_Tab.browse, kind == LibraryKind.music ? 'Albums' : 'All'),
      if (kind == LibraryKind.music) (_Tab.artists, 'Artists'),
      if (kind != LibraryKind.other) (_Tab.collections, 'Collections'),
      if (kind != LibraryKind.other) (_Tab.folders, 'Folders'),
    ];
    final paged = tab == _Tab.browse || tab == _Tab.artists;

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
                  for (final (t, label) in tabs) ...[
                    ChoiceChip(
                      label: Text(label),
                      selected: t == tab,
                      onSelected: (_) => _setTab(t),
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
                    if (lib != null &&
                        _query.view == LibraryView.items &&
                        (ref.watch(filterCategoriesProvider(widget.libraryRef))
                                    .value ??
                                const [])
                            .isNotEmpty) ...[
                      const SizedBox(width: 8),
                      ActionChip(
                        focusNode: _filterButton,
                        avatar: const Icon(Icons.filter_list_rounded, size: 18),
                        label: Text(_query.filterCount == 0
                            ? 'Filter'
                            : 'Filter (${_query.filterCount})'),
                        onPressed: () => _openFilters(
                            lib,
                            ref
                                .read(filterCategoriesProvider(widget.libraryRef))
                                .value!),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          // What's filtered, each removable (OK on a chip removes it).
          if (paged &&
              _query.view == LibraryView.items &&
              _query.filterCount > 0)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(l.gutter, 2, l.gutter, 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final e in _query.filters.entries)
                      for (final v in e.value)
                        InputChip(
                          label: Text(v.title),
                          tooltip: 'Remove ${v.title}',
                          onPressed: () => _removeFilter(e.key, v),
                          onDeleted: () => _removeFilter(e.key, v),
                        ),
                    TextButton(
                      onPressed: () {
                        _setQuery(_query.copyWith(filters: const {}));
                        _focusFilterButton();
                      },
                      child: const Text('Clear all'),
                    ),
                  ],
                ),
              ),
            ),
          if (tab == _Tab.recommended)
            _RecommendedRows(
              value: ref.watch(libraryRecommendedProvider(widget.libraryRef)),
              onRetry: () => ref
                  .invalidate(libraryRecommendedProvider(widget.libraryRef)),
            )
          else if (tab == _Tab.collections)
            _ProviderGrid(
              value: ref.watch(libraryCollectionsProvider(widget.libraryRef)),
              empty: 'No collections in this library',
            )
          else if (tab == _Tab.folders)
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
              child: _query.filterCount > 0 &&
                      _query.view == LibraryView.items
                  ? MessageView(
                      icon: Icons.filter_list_off_rounded,
                      title: 'Nothing matches these filters',
                      body: 'Remove a filter, or clear them all.',
                      action: 'Clear all',
                      onAction: () =>
                          _setQuery(_query.copyWith(filters: const {})),
                    )
                  : MessageView(
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

/// The Recommended tab: the server's rows for this library.
class _RecommendedRows extends StatelessWidget {
  const _RecommendedRows({required this.value, required this.onRetry});
  final AsyncValue<List<Shelf>> value;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tv = AppLayout.of(context).tv;
    return value.when(
      loading: () => SliverList.list(children: const [
        ShelfSkeleton(title: '', shape: CardShape.landscape),
        ShelfSkeleton(title: '', shape: CardShape.poster),
      ]),
      error: (e, _) => SliverFillRemaining(
          hasScrollBody: false,
          child: MessageView.error(e, onRetry: onRetry)),
      data: (shelves) => shelves.isEmpty
          ? const SliverFillRemaining(
              hasScrollBody: false,
              child: MessageView(
                icon: Icons.auto_awesome_outlined,
                title: 'Nothing to recommend yet',
                body: 'Watch something from this library and suggestions '
                    'will show up here.',
              ),
            )
          : SliverList.list(children: [
              for (var i = 0; i < shelves.length; i++)
                MediaShelf(
                  title: shelves[i].title,
                  items: shelves[i].items,
                  shape: shelves[i].landscape ? CardShape.landscape : null,
                  // Wide rows are continue watching / next up: play them.
                  playOnTap: shelves[i].landscape,
                  autofocusFirst: tv && i == 0,
                ),
              const SizedBox(height: 24),
            ]),
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

/// Filter panel: categories, then one category's values. Ticking a value
/// applies at once (the grid behind updates); Back returns to the
/// categories, then closes.
class _FilterPanel extends ConsumerStatefulWidget {
  const _FilterPanel({
    required this.library,
    required this.categories,
    required this.query,
    required this.onChanged,
  });
  final Library library;
  final List<FilterCategory> categories;
  final LibraryQuery query;
  final ValueChanged<LibraryQuery> onChanged;

  @override
  ConsumerState<_FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends ConsumerState<_FilterPanel> {
  late LibraryQuery _query = widget.query;
  FilterCategory? _open;
  bool _showMore = false;

  /// The values as shown, chosen ones first — ordered once per load so a
  /// tick never moves the row the remote is on.
  List<FilterValue>? _values;

  /// A category's full list, kept so search filters it in the app (Plex
  /// sends every actor at once). Null when the server must search (Jellyfin
  /// people: nothing until a name is typed).
  List<FilterValue>? _all;
  Object? _error;
  final _search = TextEditingController();
  int _loadGeneration = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<FilterValue> _chosen(FilterCategory c) =>
      _query.filters[c.id] ?? const [];

  Future<void> _openCategory(FilterCategory c) async {
    _search.clear();
    setState(() {
      _open = c;
      _values = null;
      _all = null;
      _error = null;
    });
    await _load();
  }

  List<FilterValue> _chosenFirst(FilterCategory c, List<FilterValue> values) {
    final chosen = _chosen(c);
    return [
      ...chosen.where(values.contains),
      ...values.where((v) => !chosen.contains(v)),
    ];
  }

  Future<void> _load() async {
    final c = _open;
    if (c == null) return;
    final q = _search.text.trim().toLowerCase();
    final all = _all;
    if (all != null) {
      // Search what's already here.
      setState(() => _values = _chosenFirst(
          c,
          q.isEmpty
              ? all
              : all.where((v) => v.title.toLowerCase().contains(q)).toList()));
      return;
    }
    final generation = ++_loadGeneration;
    final backend = ref.read(backendsProvider)[widget.library.serverId];
    try {
      final values = await backend!.filterValues(widget.library, c,
          search: c.searchable && q.isNotEmpty ? _search.text : null);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        // A full list (anything before a search) is kept for searching.
        if (q.isEmpty && values.isNotEmpty) _all = values;
        _values = _chosenFirst(c, values);
      });
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = e);
      }
    }
  }

  void _toggle(FilterCategory c, FilterValue v) {
    final current = _chosen(c);
    final next = current.contains(v)
        ? [for (final x in current) if (x != v) x]
        : [...current, v];
    final filters = {..._query.filters, c.id: next}
      ..removeWhere((_, values) => values.isEmpty);
    setState(() => _query = _query.copyWith(filters: filters));
    widget.onChanged(_query);
  }

  @override
  Widget build(BuildContext context) {
    final open = _open;
    return PopScope(
      // Back from a category's values returns to the list of categories.
      canPop: open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && open != null) setState(() => _open = null);
      },
      child: open == null ? _categories() : _valuesOf(open),
    );
  }

  Widget _categories() {
    final everyday = widget.categories.where((c) => !c.more).toList();
    final more = widget.categories.where((c) => c.more).toList();
    Widget row(FilterCategory c, {required bool first}) {
      final chosen = _chosen(c);
      return ListTile(
        autofocus: first,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        focusColor: Palette.surfaceHigh,
        title: Text(c.title),
        subtitle: chosen.isEmpty
            ? null
            : Text(chosen.map((v) => v.title).join(', '),
                maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _openCategory(c),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('Filter',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
                'Choices in one category show either; categories narrow '
                'each other.',
                style: TextStyle(color: Palette.muted)),
          ),
          // Eager rows: a lazy list never builds off-screen autofocus.
          for (final (i, c) in everyday.indexed) row(c, first: i == 0),
          if (more.isNotEmpty && !_showMore)
            ListTile(
              autofocus: everyday.isEmpty,
              leading: const Icon(Icons.expand_more_rounded),
              title: const Text('More filters'),
              onTap: () => setState(() => _showMore = true),
            ),
          if (_showMore)
            for (final (i, c) in more.indexed)
              row(c, first: everyday.isEmpty && i == 0),
          if (_query.filterCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() =>
                        _query = _query.copyWith(filters: const {}));
                    widget.onChanged(_query);
                  },
                  icon: const Icon(Icons.filter_list_off_rounded),
                  label: const Text('Clear all filters'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _valuesOf(FilterCategory c) {
    // Chosen ones first (ordered when loaded, not on every tick).
    final ordered = _values;
    final chosen = _chosen(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 16, 4),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => setState(() => _open = null),
              ),
              Expanded(
                child: Text(c.title,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w700)),
              ),
              if (chosen.isNotEmpty)
                Text('${chosen.length} chosen',
                    style: const TextStyle(color: Palette.muted)),
            ],
          ),
        ),
        if (c.searchable)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: RemoteTextField(
              child: TextField(
                controller: _search,
                // Nothing else in the panel is focused when it opens.
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search ${c.title.toLowerCase()}',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: phoneTypeButton(context, _search,
                      label: c.title, onText: (_) => _load()),
                ),
                onChanged: (_) => _load(),
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(friendlyError(_error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          )
        else if (ordered == null)
          const Padding(padding: EdgeInsets.all(32), child: Loading())
        else if (ordered.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
                c.searchable && _search.text.trim().isEmpty
                    ? 'Type a name to search.'
                    : 'Nothing to choose here.',
                style: const TextStyle(color: Palette.muted)),
          )
        else
          // Lazy: a category can hold hundreds of names.
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
              itemCount: ordered.length,
              itemBuilder: (context, i) {
                final v = ordered[i];
                final on = chosen.contains(v);
                return ListTile(
                  key: ValueKey(v.id),
                  autofocus: i == 0 && !c.searchable,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  focusColor: Palette.surfaceHigh,
                  leading: Icon(
                      on
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      color: on ? Palette.accent : Palette.muted),
                  title: Text(v.title),
                  onTap: () => _toggle(c, v),
                );
              },
            ),
          ),
      ],
    );
  }
}
