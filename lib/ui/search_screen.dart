import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../core/seerr.dart';
import 'explore_screen.dart';
import 'phone_input.dart';
import 'theme.dart';
import 'widgets.dart';

/// One box that searches every connected server at once, plus the request
/// service for things you don't have yet.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.initialQuery});
  final String? initialQuery;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final _controller =
      TextEditingController(text: widget.initialQuery ?? '');
  late String _query = widget.initialQuery ?? '';

  static const _order = [
    MediaKind.movie,
    MediaKind.show,
    MediaKind.episode,
    MediaKind.collection,
    MediaKind.playlist,
    MediaKind.artist,
    MediaKind.album,
    MediaKind.track,
    MediaKind.video,
  ];

  @override
  void didUpdateWidget(SearchScreen old) {
    super.didUpdateWidget(old);
    final q = widget.initialQuery;
    if (q != null && q != old.initialQuery) {
      _controller.text = q;
      _query = q;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLayout.of(context);
    final active = _query.trim().length >= 2;
    final results = active ? ref.watch(searchProvider(_query)) : null;
    final external = active
        ? (ref.watch(seerrSearchProvider(_query)).value ?? const <SeerrItem>[])
        : const <SeerrItem>[];
    // Only suggest requesting things that are not already on a server.
    final requestable =
        external.where((e) => e.status != SeerrStatus.available).toList();

    final grouped = <MediaKind, List<MediaItem>>{};
    for (final i in results?.value ?? const <MediaItem>[]) {
      grouped.putIfAbsent(i.kind, () => []).add(i);
    }
    final empty =
        results != null && results.hasValue && grouped.isEmpty && requestable.isEmpty;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(l.gutter, 16, l.gutter, 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: RemoteTextField(
                  child: TextField(
                  controller: _controller,
                  autofocus: !l.tv && widget.initialQuery == null && !l.phone,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 17),
                  decoration: InputDecoration(
                    hintText: 'Movies, shows, music, people…',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _query.isEmpty
                        ? phoneTypeButton(context, _controller,
                            label: 'Search',
                            onText: (v) => setState(() => _query = v))
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              _controller.clear();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                )),
              ),
            ),
            Expanded(
              child: !active
                  ? const MessageView(
                      icon: Icons.search_rounded,
                      title: 'Search everything',
                      body: 'Results come from all of your servers at once.',
                    )
                  : (results!.isLoading && !results.hasValue)
                      ? const Loading()
                      : empty
                          ? MessageView(
                              icon: Icons.search_off_rounded,
                              title: 'No results for "${_query.trim()}"',
                              body: 'Check the spelling or try fewer words.',
                            )
                          : ListView(
                              padding: const EdgeInsets.only(bottom: 32),
                              children: [
                                for (final kind in _order)
                                  if (grouped[kind] != null)
                                    MediaShelf(
                                      title: kind.label,
                                      items: grouped[kind]!,
                                      shape: kind == MediaKind.episode
                                          ? CardShape.landscape
                                          : null,
                                    ),
                                if (requestable.isNotEmpty)
                                  SeerrShelf(
                                    title: 'Not in your libraries — request',
                                    items: requestable,
                                  ),
                              ],
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
