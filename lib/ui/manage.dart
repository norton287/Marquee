import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/backend.dart';
import '../core/models.dart';
import '../core/providers.dart';
import 'theme.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Manage menu: refresh, analyze, fix match, unmatch, poster, background
// ---------------------------------------------------------------------------

/// The "Manage" button on a details page. Shows nothing when the server
/// offers no actions for this item (or the user may not manage it).
class ManageButton extends ConsumerWidget {
  const ManageButton({super.key, required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.watch(manageActionsProvider(item.ref)).value;
    if (actions == null || actions.isEmpty) return const SizedBox.shrink();
    return SelectMenu(
      items: [
        for (final a in ManageAction.values)
          if (actions.contains(a))
            SelectMenuItem(
              label: a.label,
              icon: _icon(a),
              onPressed: () => _run(context, ref, a),
            ),
      ],
      builder: (context, focusNode, toggle) => IconButton.outlined(
        focusNode: focusNode,
        tooltip: 'Manage',
        onPressed: toggle,
        icon: const Icon(Icons.tune_rounded),
      ),
    );
  }

  static IconData _icon(ManageAction a) => switch (a) {
        ManageAction.edit => Icons.edit_outlined,
        ManageAction.refresh => Icons.refresh_rounded,
        ManageAction.analyze => Icons.analytics_outlined,
        ManageAction.match => Icons.manage_search_rounded,
        ManageAction.unmatch => Icons.link_off_rounded,
        ManageAction.poster => Icons.image_outlined,
        ManageAction.upload => Icons.upload_file_rounded,
        ManageAction.background => Icons.wallpaper_rounded,
        ManageAction.uploadBackground => Icons.add_photo_alternate_outlined,
        ManageAction.delete => Icons.delete_forever_outlined,
        ManageAction.removeFromPlaylist => Icons.remove_circle_outline_rounded,
        ManageAction.deletePlaylist => Icons.playlist_remove_rounded,
      };

  Future<void> _run(BuildContext context, WidgetRef ref, ManageAction a) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final backend = container.read(backendsProvider)[item.serverId];
    if (backend == null) return;
    void say(String text) =>
        (messenger..hideCurrentSnackBar()).showSnackBar(SnackBar(content: Text(text)));

    switch (a) {
      case ManageAction.delete || ManageAction.deletePlaylist:
        final router = GoRouter.of(context);
        final ok = await showDialog<bool>(
            context: context, builder: (_) => _DeleteDialog(item: item));
        if (ok != true) return;
        try {
          if (a == ManageAction.deletePlaylist) {
            await backend.deletePlaylist(item);
          } else {
            await backend.deleteItem(item);
          }
        } catch (e) {
          say(friendlyError(e));
          return;
        }
        // The page's item no longer exists: leave it, then clear it out of
        // every list.
        if (router.canPop()) {
          router.pop();
        } else {
          router.go('/home');
        }
        say('Deleted ${item.title}');
        itemDeleted(container, item);
      case ManageAction.edit:
        await showPanel<void>(context,
            width: 460, builder: (_) => _EditPanel(item: item));
      case ManageAction.upload || ManageAction.uploadBackground:
        await showPanel<void>(context,
            width: 460,
            builder: (_) => _UploadPanel(
                item: item,
                kind: a == ManageAction.upload
                    ? ArtworkKind.poster
                    : ArtworkKind.background));
      case ManageAction.removeFromPlaylist:
        await showPanel<void>(context,
            width: 460,
            builder: (_) => _RemoveFromPlaylistPanel(playlist: item));
      case ManageAction.match:
        await showPanel<void>(context,
            width: 460, builder: (_) => _MatchPanel(item: item));
      case ManageAction.poster || ManageAction.background:
        await showPanel<void>(context,
            width: 460,
            builder: (_) => _ArtworkPanel(
                item: item,
                kind: a == ManageAction.poster
                    ? ArtworkKind.poster
                    : ArtworkKind.background));
      case ManageAction.unmatch:
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Unmatch ${item.title}?'),
            content: const Text('The server forgets what this title was '
                'matched to and keeps only what it can read from the file.'),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Unmatch'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        try {
          await backend.unmatch(item);
          say('Unmatched ${item.title}');
          reloadItem(container, item, again: true);
        } catch (e) {
          say(friendlyError(e));
        }
      case ManageAction.refresh || ManageAction.analyze:
        try {
          if (a == ManageAction.refresh) {
            await backend.refreshMetadata(item);
          } else {
            await backend.analyze(item);
          }
          say(a == ManageAction.refresh
              ? 'Refreshing metadata for ${item.title}…'
              : 'Analyzing ${item.title}…');
          reloadItem(container, item, again: true);
        } catch (e) {
          say(friendlyError(e));
        }
    }
  }
}

/// Asks before deleting. Cancel has focus, so a stray OK on a remote
/// can't delete anything.
class _DeleteDialog extends StatelessWidget {
  const _DeleteDialog({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final playlist = item.kind == MediaKind.playlist;
    final what = switch (item.kind) {
      MediaKind.show => 'every season and episode of this show',
      MediaKind.season => 'every episode in this season',
      MediaKind.episode => "this episode's files",
      _ => "this movie's files",
    };
    final error = Theme.of(context).colorScheme.error;
    return AlertDialog(
      icon: Icon(
          playlist
              ? Icons.playlist_remove_rounded
              : Icons.delete_forever_outlined,
          color: error),
      title: Text(playlist
          ? 'Delete the playlist "${item.title}"?'
          : 'Delete ${item.title}?'),
      content: Text(playlist
          ? 'This removes the playlist from the server. What\'s in it stays '
              'in your libraries. It can\'t be undone.'
          : 'This permanently deletes $what from the server\'s '
              'disk. It can\'t be undone.'),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: error,
              foregroundColor: Theme.of(context).colorScheme.onError),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}

/// Wraps a text field so ↑/↓ on a remote move focus out of it. Text fields
/// normally keep the arrow keys, which traps a D-pad inside the field.
class _RemoteTextField extends StatelessWidget {
  const _RemoteTextField({required this.child, this.multiline});
  final Widget child;

  /// For a multi-line field: ↑/↓ only leave it from the first / last line,
  /// so a keyboard can still move between lines.
  final TextEditingController? multiline;

  bool _atEdge(TraversalDirection dir) {
    final c = multiline;
    if (c == null) return true;
    final caret = c.selection.isValid ? c.selection.extentOffset : 0;
    return dir == TraversalDirection.up
        ? !c.text.substring(0, caret.clamp(0, c.text.length)).contains('\n')
        : !c.text.substring(caret.clamp(0, c.text.length)).contains('\n');
  }

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if (event is KeyUpEvent) return KeyEventResult.ignored;
          final dir = switch (event.logicalKey) {
            LogicalKeyboardKey.arrowDown => TraversalDirection.down,
            LogicalKeyboardKey.arrowUp => TraversalDirection.up,
            _ => null,
          };
          if (dir == null || !_atEdge(dir)) return KeyEventResult.ignored;
          FocusManager.instance.primaryFocus?.focusInDirection(dir);
          return KeyEventResult.handled;
        },
        child: child,
      );
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle(this.title, {this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            if (subtitle != null)
              Text(subtitle!,
                  style: const TextStyle(color: Palette.muted, fontSize: 13)),
          ],
        ),
      );
}

/// A picked image file: its bytes and file name.
typedef PickedImage = ({Uint8List bytes, String name});

/// Opens the system file browser for an image. Tests swap this out.
@visibleForTesting
Future<PickedImage?> Function() pickImageFile = () async {
  final file = await FilePicker.pickFile(type: FileType.image);
  if (file == null) return null;
  return (bytes: await file.xFile.readAsBytes(), name: file.name);
};

/// Upload an image of your own: a file from this device, or a link the
/// server downloads (the only option on TVs without a file browser).
class _UploadPanel extends ConsumerStatefulWidget {
  const _UploadPanel({required this.item, required this.kind});
  final MediaItem item;
  final ArtworkKind kind;

  @override
  ConsumerState<_UploadPanel> createState() => _UploadPanelState();
}

class _UploadPanelState extends ConsumerState<_UploadPanel> {
  static const _maxBytes = 15 * 1024 * 1024;
  final _url = TextEditingController();
  final _uploadButton = FocusNode(debugLabel: 'upload file');
  PickedImage? _file;
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _url.dispose();
    _uploadButton.dispose();
    super.dispose();
  }

  bool get _urlOk {
    final u = Uri.tryParse(_url.text.trim());
    return u != null && (u.scheme == 'http' || u.scheme == 'https') &&
        u.host.isNotEmpty;
  }

  static String _mime(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Future<void> _choose() async {
    setState(() => _error = null);
    try {
      final f = await pickImageFile();
      if (f == null || !mounted) return;
      if (f.bytes.length > _maxBytes) {
        setState(() => _error =
            const FormatException('That image is over 15 MB. Pick a smaller one.'));
        return;
      }
      setState(() => _file = f);
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _uploadButton.requestFocus());
    } catch (_) {
      // Many Android TVs ship without a document browser.
      if (mounted) {
        setState(() => _error = const FormatException(
            'This device has no file browser. Use an image link instead.'));
      }
    }
  }

  Future<void> _upload({PickedImage? file, String? url}) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final backend = container.read(backendsProvider)[widget.item.serverId];
    if (backend == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await backend.uploadArtwork(widget.item, widget.kind,
          bytes: file?.bytes,
          mimeType: file == null ? null : _mime(file.name),
          url: url);
      reloadItem(container, widget.item);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      (messenger..hideCurrentSnackBar()).showSnackBar(
          SnackBar(content: Text('${widget.kind.label} uploaded')));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    final label = widget.kind.label.toLowerCase();
    const heading = TextStyle(
        fontSize: 11.5,
        letterSpacing: 1.3,
        fontWeight: FontWeight.w800,
        color: Palette.muted);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelTitle('Upload $label', subtitle: widget.item.title),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('FROM THIS DEVICE', style: heading),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    autofocus: true,
                    onPressed: _busy ? null : _choose,
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: Text(file == null
                        ? 'Choose an image…'
                        : 'Choose a different image…'),
                  ),
                ),
                if (file != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      SizedBox(
                        width: 96,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: AspectRatio(
                            aspectRatio: widget.kind == ArtworkKind.poster
                                ? 2 / 3
                                : 16 / 9,
                            child: Image.memory(file.bytes,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const ColoredBox(
                                    color: Palette.surfaceHigh,
                                    child: Icon(Icons.broken_image_outlined))),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(file.name,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              focusNode: _uploadButton,
                              onPressed:
                                  _busy ? null : () => _upload(file: file),
                              icon: const Icon(Icons.upload_rounded, size: 18),
                              label: Text(_busy ? 'Uploading…' : 'Upload'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
                const Text('FROM A LINK', style: heading),
                const SizedBox(height: 8),
                _RemoteTextField(
                  child: TextField(
                    controller: _url,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                        hintText: 'https://…/image.jpg'),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) =>
                        _urlOk ? _upload(url: _url.text.trim()) : null,
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _busy || !_urlOk
                        ? null
                        : () => _upload(url: _url.text.trim()),
                    icon: const Icon(Icons.link_rounded, size: 18),
                    label: const Text('Use this link'),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(friendlyError(_error!),
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Edit an item's title and summary.
class _EditPanel extends ConsumerStatefulWidget {
  const _EditPanel({required this.item});
  final MediaItem item;

  @override
  ConsumerState<_EditPanel> createState() => _EditPanelState();
}

class _EditPanelState extends ConsumerState<_EditPanel> {
  late final _title = TextEditingController(text: widget.item.title);
  late final _summary =
      TextEditingController(text: widget.item.overview ?? '');
  bool _saving = false;
  Object? _error;

  @override
  void dispose() {
    _title.dispose();
    _summary.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final summary = _summary.text.trim();
    if (title.isEmpty) {
      setState(() => _error = const FormatException('The title can\'t be empty'));
      return;
    }
    if (title == widget.item.title && summary == (widget.item.overview ?? '')) {
      Navigator.pop(context);
      return;
    }
    final container = ProviderScope.containerOf(context, listen: false);
    final backend = container.read(backendsProvider)[widget.item.serverId];
    if (backend == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await backend.editDetails(widget.item, title: title, summary: summary);
      reloadItem(container, widget.item);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      (messenger..hideCurrentSnackBar())
          .showSnackBar(SnackBar(content: Text('Saved changes to $title')));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _PanelTitle('Edit details',
              subtitle: 'Edited fields are locked so a metadata refresh '
                  'keeps them.'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _RemoteTextField(
                  child: TextField(
                    controller: _title,
                    autofocus: true,
                    enabled: !_saving,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                ),
                const SizedBox(height: 14),
                _RemoteTextField(
                  multiline: _summary,
                  child: TextField(
                    controller: _summary,
                    enabled: !_saving,
                    minLines: 4,
                    maxLines: 10,
                    textCapitalization: TextCapitalization.sentences,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration(
                        labelText: 'Summary', alignLabelWithHint: true),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(friendlyError(_error!),
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed:
                          _saving ? null : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? 'Saving…' : 'Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Search the server's agents for the right title and apply one.
class _MatchPanel extends ConsumerStatefulWidget {
  const _MatchPanel({required this.item});
  final MediaItem item;

  @override
  ConsumerState<_MatchPanel> createState() => _MatchPanelState();
}

class _MatchPanelState extends ConsumerState<_MatchPanel> {
  late final _title = TextEditingController(text: widget.item.title);
  late final _year =
      TextEditingController(text: widget.item.year?.toString() ?? '');
  final _searchButton = FocusNode(debugLabel: 'match search');
  final _firstResult = FocusNode(debugLabel: 'match result 0');
  List<MatchCandidate>? _results;
  Object? _error;
  bool _searching = false;
  String? _applying;

  @override
  void initState() {
    super.initState();
    // Start with what the server thinks the title is.
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _title.dispose();
    _year.dispose();
    _searchButton.dispose();
    _firstResult.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final backend = ref.read(backendsProvider)[widget.item.serverId];
    if (backend == null || _title.text.trim().isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await backend.searchMatches(widget.item,
          title: _title.text.trim(), year: int.tryParse(_year.text.trim()));
      if (!mounted) return;
      setState(() => _results = results);
      // Put the remote on the best result (or back on Search if none).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        (results.isEmpty ? _searchButton : _firstResult).requestFocus();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
      _searchButton.requestFocus();
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _apply(MatchCandidate m) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final backend = container.read(backendsProvider)[widget.item.serverId];
    if (backend == null) return;
    setState(() => _applying = m.id);
    try {
      await backend.applyMatch(widget.item, m);
      reloadItem(container, widget.item, again: true);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      (messenger..hideCurrentSnackBar()).showSnackBar(SnackBar(
          content: Text('Matched to ${m.title}'
              '${m.year != null ? ' (${m.year})' : ''}')));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _applying = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelTitle('Fix match',
              subtitle: 'Search for what this title really is.'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: _RemoteTextField(
                    child: TextField(
                      controller: _title,
                      decoration: const InputDecoration(labelText: 'Title'),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 84,
                  child: _RemoteTextField(
                    child: TextField(
                      controller: _year,
                      decoration: const InputDecoration(labelText: 'Year'),
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                focusNode: _searchButton,
                onPressed: _searching ? null : _search,
                icon: const Icon(Icons.search_rounded, size: 18),
                label: Text(_searching ? 'Searching…' : 'Search'),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(friendlyError(_error!),
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (results != null && results.isEmpty && !_searching)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No matches. Try a different title or year.',
                  style: TextStyle(color: Palette.muted)),
            ),
          if (results != null)
            for (final (i, m) in results.indexed)
              ListTile(
                focusNode: i == 0 ? _firstResult : null,
                enabled: _applying == null,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                focusColor: Palette.surfaceHigh,
                leading: SizedBox(
                  width: 40,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Artwork(
                        image: m.image,
                        icon: Icons.movie_outlined,
                        seed: m.title),
                  ),
                ),
                title: Text(
                    '${m.title}${m.year != null ? ' (${m.year})' : ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [
                    ?m.source,
                    if (m.score != null) '${m.score}% match',
                    if ((m.overview ?? '').isNotEmpty) m.overview!,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: _applying == m.id
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
                onTap: () => _apply(m),
              ),
        ],
      ),
    );
  }
}

/// Pick a poster or background from what the server's agents offer.
class _ArtworkPanel extends ConsumerStatefulWidget {
  const _ArtworkPanel({required this.item, required this.kind});
  final MediaItem item;
  final ArtworkKind kind;

  @override
  ConsumerState<_ArtworkPanel> createState() => _ArtworkPanelState();
}

class _ArtworkPanelState extends ConsumerState<_ArtworkPanel> {
  late final Future<List<ArtworkOption>> _options = ref
      .read(backendsProvider)[widget.item.serverId]!
      .artwork(widget.item, widget.kind);
  String? _setting;
  Object? _error;

  Future<void> _set(ArtworkOption o) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final backend = container.read(backendsProvider)[widget.item.serverId];
    if (backend == null) return;
    setState(() => _setting = o.id);
    try {
      await backend.setArtwork(widget.item, widget.kind, o);
      reloadItem(container, widget.item);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      (messenger..hideCurrentSnackBar()).showSnackBar(
          SnackBar(content: Text('${widget.kind.label} updated')));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _setting = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final poster = widget.kind == ArtworkKind.poster;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelTitle('Change ${widget.kind.label.toLowerCase()}',
              subtitle: widget.item.title),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(friendlyError(_error!),
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          FutureBuilder<List<ArtworkOption>>(
            future: _options,
            builder: (context, snap) {
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(friendlyError(snap.error!),
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                );
              }
              final options = snap.data;
              if (options == null) {
                return const Padding(
                    padding: EdgeInsets.all(32), child: Loading());
              }
              if (options.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('The server has no other images for this.',
                      style: TextStyle(color: Palette.muted)),
                );
              }
              final current = options.indexWhere((o) => o.selected);
              return LayoutBuilder(builder: (context, c) {
                final cols = poster ? 3 : 2;
                const gap = 12.0;
                final w = (c.maxWidth - 16 - gap * (cols - 1)) / cols;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final (i, o) in options.indexed)
                        SizedBox(
                          width: w,
                          child: Pressable(
                            // Start on the image in use (or the first).
                            autofocus: i == (current < 0 ? 0 : current),
                            onTap: _setting == null ? () => _set(o) : null,
                            builder: (context, focused, hovered) => Stack(
                              children: [
                                ArtFrame(
                                  focused: focused,
                                  hovered: hovered,
                                  radius: 8,
                                  // Artwork's aspect only picks the image
                                  // size; the tile needs its own height or
                                  // the image gets an unbounded one and
                                  // nothing is painted (blank panel on TV).
                                  child: AspectRatio(
                                    aspectRatio: poster ? 2 / 3 : 16 / 9,
                                    child: Artwork(
                                      image: o.image,
                                      aspect: poster ? 2 / 3 : 16 / 9,
                                      seed: o.id,
                                    ),
                                  ),
                                ),
                                if (o.selected || _setting == o.id)
                                  Positioned(
                                    right: 6,
                                    top: 6,
                                    child: CircleAvatar(
                                      radius: 12,
                                      backgroundColor: Palette.accent,
                                      child: _setting == o.id
                                          ? const SizedBox(
                                              width: 12,
                                              height: 12,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Colors.white))
                                          : const Icon(Icons.check_rounded,
                                              size: 16, color: Colors.white),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              });
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Remove from playlist
// ---------------------------------------------------------------------------

/// The playlist's videos; OK takes one out straight away (nothing is lost:
/// Add to playlist puts it back). Focus stays in the list so several can go.
class _RemoveFromPlaylistPanel extends ConsumerStatefulWidget {
  const _RemoveFromPlaylistPanel({required this.playlist});
  final MediaItem playlist;

  @override
  ConsumerState<_RemoveFromPlaylistPanel> createState() =>
      _RemoveFromPlaylistPanelState();
}

class _RemoveFromPlaylistPanelState
    extends ConsumerState<_RemoveFromPlaylistPanel> {
  List<MediaItem>? _entries;
  Object? _error;
  String? _removing;
  final _nodes = <String, FocusNode>{};

  MediaBackend? get _backend =>
      ref.read(backendsProvider)[widget.playlist.serverId];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _backend!.children(widget.playlist);
      if (mounted) setState(() => _entries = list);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  FocusNode _node(MediaItem e) => _nodes[e.playlistEntryId ?? e.id] ??=
      FocusNode(debugLabel: 'playlist entry ${e.title}');

  @override
  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  Future<void> _remove(MediaItem entry) async {
    final backend = _backend;
    final entries = _entries;
    // Rows stay enabled while a request runs (a disabled row drops the
    // remote's focus); a second OK meanwhile is ignored here instead.
    if (backend == null || entries == null || _removing != null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final at = entries.indexOf(entry);
    setState(() {
      _removing = entry.playlistEntryId;
      _error = null;
    });
    try {
      await backend.removeFromPlaylist(widget.playlist, entry);
    } catch (e) {
      // A snackbar shows however far the list is scrolled, and even if the
      // panel was closed before the server answered.
      (messenger..hideCurrentSnackBar())
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      if (mounted) {
        setState(() => _removing = null);
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _node(entry).requestFocus());
      }
      return;
    }
    (messenger..hideCurrentSnackBar())
        .showSnackBar(SnackBar(content: Text('Removed ${entry.title}')));
    reloadItem(container, widget.playlist);
    container.invalidate(playlistsProvider(widget.playlist.serverId));
    if (!mounted) return;
    final left = [...entries]..removeAt(at);
    setState(() {
      _entries = left;
      _removing = null;
    });
    // Keep the remote in the list: the next video, or the one before.
    if (left.isNotEmpty) {
      final next = left[at.clamp(0, left.length - 1)];
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _node(next).requestFocus());
    }
    _nodes.remove(entry.playlistEntryId ?? entry.id)?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _PanelTitle('Remove from playlist',
              subtitle: widget.playlist.title),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(friendlyError(_error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (entries == null && _error == null)
          const Padding(padding: EdgeInsets.all(32), child: Loading())
        else if (entries != null && entries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('This playlist is empty.',
                style: TextStyle(color: Palette.muted)),
          )
        else if (entries != null)
          // Lazy: a long (music) playlist only builds and loads the rows on
          // screen. Focus still works: the first row is always built for
          // its autofocus, the row after a removal sits where the removed
          // one was, and the list builds a little past its edges for ↓.
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
              itemCount: entries.length,
              itemBuilder: (context, i) => _row(entries[i], first: i == 0),
            ),
          ),
      ],
    );
  }

  Widget _row(MediaItem e, {required bool first}) => Pressable(
        key: ValueKey(e.playlistEntryId ?? e.id),
        focusNode: _node(e),
        autofocus: first,
        grow: 1,
        onTap: () => _remove(e),
        builder: (context, focused, hovered) => Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: focused || hovered ? Palette.surfaceHigh : null,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: focused ? Colors.white : Colors.transparent, width: 2),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 96,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Artwork(
                      image: e.thumb ?? e.backdrop ?? e.poster,
                      aspect: 16 / 9,
                      seed: e.title,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.cardTitle,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (e.cardSubtitle case final sub?)
                      Text(sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Palette.muted, fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _removing == e.playlistEntryId
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.remove_circle_outline_rounded,
                      color: focused ? Colors.white : Palette.muted),
            ],
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// Add to playlist
// ---------------------------------------------------------------------------

class AddToPlaylistButton extends ConsumerWidget {
  const AddToPlaylistButton({super.key, required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.watch(backendsProvider)[item.serverId];
    if (backend == null || !backend.canAddToPlaylist(item)) {
      return const SizedBox.shrink();
    }
    return IconButton.outlined(
      tooltip: 'Add to playlist',
      onPressed: () => showPanel<void>(context,
          builder: (_) => _PlaylistPanel(item: item)),
      icon: const Icon(Icons.playlist_add_rounded),
    );
  }
}

class _PlaylistPanel extends ConsumerStatefulWidget {
  const _PlaylistPanel({required this.item});
  final MediaItem item;

  @override
  ConsumerState<_PlaylistPanel> createState() => _PlaylistPanelState();
}

class _PlaylistPanelState extends ConsumerState<_PlaylistPanel> {
  String? _busy;

  Future<void> _done(Future<void> Function() action, String playlist) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      container
        ..invalidate(playlistsProvider(widget.item.serverId))
        ..invalidate(childrenProvider)
        ..invalidate(itemProvider);
      if (mounted) Navigator.pop(context);
      (messenger..hideCurrentSnackBar()).showSnackBar(
          SnackBar(content: Text('Added to "$playlist"')));
    } catch (e) {
      (messenger..hideCurrentSnackBar()).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _create() async {
    final name = await showDialog<String>(
        context: context, builder: (_) => const _NewPlaylistDialog());
    if (name == null || name.trim().isEmpty || !mounted) return;
    final backend = ref.read(backendsProvider)[widget.item.serverId]!;
    setState(() => _busy = '+');
    await _done(
        () => backend.createPlaylist(name.trim(), widget.item), name.trim());
  }

  @override
  Widget build(BuildContext context) {
    final lists = ref.watch(playlistsForProvider(widget.item.ref));
    final backend = ref.watch(backendsProvider)[widget.item.serverId];
    Widget? spinner(String id) => _busy == id
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2))
        : null;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelTitle('Add to playlist', subtitle: widget.item.title),
          ListTile(
            autofocus: true,
            enabled: _busy == null,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            focusColor: Palette.surfaceHigh,
            leading: const Icon(Icons.add_rounded, color: Palette.accent),
            title: const Text('New playlist…'),
            trailing: spinner('+'),
            onTap: _create,
          ),
          switch (lists) {
            AsyncData(:final value) => Column(
                children: [
                  for (final p in value)
                    ListTile(
                      enabled: _busy == null,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      focusColor: Palette.surfaceHigh,
                      leading: const Icon(Icons.queue_music_rounded),
                      title: Text(p.title),
                      subtitle: p.childCount != null
                          ? Text('${p.childCount} items')
                          : null,
                      trailing: spinner(p.id),
                      onTap: backend == null
                          ? null
                          : () {
                              setState(() => _busy = p.id);
                              _done(() => backend.addToPlaylist(p, widget.item),
                                  p.title);
                            },
                    ),
                ],
              ),
            AsyncError(:final error) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text(friendlyError(error),
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            _ => const Padding(padding: EdgeInsets.all(24), child: Loading()),
          },
        ],
      ),
    );
  }
}

class _NewPlaylistDialog extends StatefulWidget {
  const _NewPlaylistDialog();

  @override
  State<_NewPlaylistDialog> createState() => _NewPlaylistDialogState();
}

class _NewPlaylistDialogState extends State<_NewPlaylistDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('New playlist'),
        content: _RemoteTextField(
          child: TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Playlist name'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _name.text),
            child: const Text('Create'),
          ),
        ],
      );
}
