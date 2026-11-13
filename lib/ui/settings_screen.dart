import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/backend.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../core/seerr.dart';
import '../core/storage.dart';
import 'add_server_screen.dart';
import 'libraries_screen.dart';
import 'theme.dart';
import 'widgets.dart';

const _languages = <(String?, String)>[
  (null, 'Default'),
  ('eng', 'English'),
  ('spa', 'Spanish'),
  ('fra', 'French'),
  ('deu', 'German'),
  ('ita', 'Italian'),
  ('por', 'Portuguese'),
  ('nld', 'Dutch'),
  ('jpn', 'Japanese'),
  ('kor', 'Korean'),
  ('zho', 'Chinese'),
  ('hin', 'Hindi'),
  ('ara', 'Arabic'),
  ('rus', 'Russian'),
];

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLayout.of(context);
    final settings = ref.watch(settingsProvider);
    final servers = ref.watch(serversProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final hasDemo = servers.any((s) => s.kind == ServerKind.demo);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: EdgeInsets.fromLTRB(l.gutter, 20, l.gutter, 40),
              children: [
                Text('Settings',
                    style: Theme.of(context).textTheme.headlineMedium),
                const _Heading('Servers'),
                _Card(children: [
                  for (final s in servers) ...[
                    ListTile(
                      leading: s.kind == ServerKind.plex &&
                              (s.userName != null || s.userThumb != null)
                          ? PlexAvatar(
                              name: s.userName ?? s.name,
                              thumb: s.userThumb,
                              size: 32,
                            )
                          : CircleAvatar(
                              radius: 16,
                              backgroundColor:
                                  serverColor(s.kind).withValues(alpha: 0.2),
                              child: Icon(Icons.dns_rounded,
                                  size: 16, color: serverColor(s.kind)),
                            ),
                      title: Text(s.name),
                      subtitle: Text([
                        switch (s.kind) {
                          ServerKind.plex => 'Plex',
                          ServerKind.jellyfin => 'Jellyfin',
                          ServerKind.demo => 'Built-in sample library',
                        },
                        ?s.userName,
                        if (s.kind != ServerKind.demo) Uri.tryParse(s.baseUrl)?.host,
                      ].nonNulls.join(' · ')),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (s.kind == ServerKind.plex &&
                              (s.homeToken ?? s.accountToken) != null)
                            IconButton(
                              tooltip: 'Switch Plex profile',
                              icon: const Icon(Icons.switch_account_rounded),
                              onPressed: () =>
                                  showPlexProfileDialog(context, ref, server: s),
                            ),
                          IconButton(
                            tooltip: 'Remove ${s.name}',
                            icon: const Icon(Icons.delete_outline_rounded),
                            onPressed: () => _confirmRemove(context, ref, s),
                          ),
                        ],
                      ),
                    ),
                    _ServerLibraries(server: s),
                    const Divider(height: 1),
                  ],
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () =>
                              context.push('/add-server?kind=plex'),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Plex'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () =>
                              context.push('/add-server?kind=jellyfin'),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Jellyfin'),
                        ),
                        if (!hasDemo)
                          OutlinedButton.icon(
                            onPressed: () => ref
                                .read(serversProvider.notifier)
                                .add(demoServer),
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('Demo library'),
                          ),
                      ],
                    ),
                  ),
                ]),
                const _Heading('Playback'),
                _Card(children: [
                  _Choice<int?>(
                    title: 'Video quality',
                    subtitle:
                        'Original plays the file untouched. Lower settings '
                        'ask the server to transcode.',
                    value: settings.maxBitrateKbps,
                    options: [
                      for (final q in QualityOption.all) (q.kbps, q.label)
                    ],
                    onChanged: (v) =>
                        notifier.change((s) => s.copyWith(maxBitrateKbps: v)),
                  ),
                  _Choice<String?>(
                    title: 'Audio language',
                    value: settings.audioLanguage,
                    options: _languages,
                    onChanged: (v) =>
                        notifier.change((s) => s.copyWith(audioLanguage: v)),
                  ),
                  _Choice<String?>(
                    title: 'Subtitles',
                    value: settings.subtitleLanguage,
                    options: [
                      (null, 'Off'),
                      ..._languages.skip(1),
                    ],
                    onChanged: (v) => notifier
                        .change((s) => s.copyWith(subtitleLanguage: v)),
                  ),
                  SwitchListTile(
                    title: const Text('Play the next episode automatically'),
                    value: settings.autoPlayNext,
                    onChanged: (v) =>
                        notifier.change((s) => s.copyWith(autoPlayNext: v)),
                  ),
                  SwitchListTile(
                    title: const Text('Skip intros automatically'),
                    subtitle: const Text(
                        'When the server has intro markers for an episode'),
                    value: settings.autoSkipIntro,
                    onChanged: (v) =>
                        notifier.change((s) => s.copyWith(autoSkipIntro: v)),
                  ),
                  _Choice<int>(
                    title: 'Skip back',
                    subtitle: 'Back button, remote rewind and ← while '
                        'the controls are hidden.',
                    value: settings.skipBackSeconds,
                    options: [
                      for (final n in AppSettings.skipOptions)
                        (n, '$n seconds')
                    ],
                    onChanged: (v) => notifier
                        .change((s) => s.copyWith(skipBackSeconds: v)),
                  ),
                  _Choice<int>(
                    title: 'Skip forward',
                    subtitle: 'Forward button, remote fast-forward and → '
                        'while the controls are hidden.',
                    value: settings.skipForwardSeconds,
                    options: [
                      for (final n in AppSettings.skipOptions)
                        (n, '$n seconds')
                    ],
                    onChanged: (v) => notifier
                        .change((s) => s.copyWith(skipForwardSeconds: v)),
                  ),
                ]),
                const _Heading('Requests'),
                _Card(children: [
                  ListTile(
                    leading: const Icon(Icons.add_task_rounded),
                    title: Text(settings.hasSeerr
                        ? 'Connected to ${Uri.tryParse(settings.seerrUrl!)?.host ?? settings.seerrUrl}'
                        : 'Connect Seerr'),
                    subtitle: const Text(
                        'Works with Seerr, Overseerr and Jellyseerr. Powers '
                        'trending and requests in Explore.'),
                    trailing: settings.hasSeerr
                        ? TextButton(
                            onPressed: () => notifier.change((s) => s.copyWith(
                                seerrUrl: null,
                                seerrApiKey: null,
                                seerrCookie: null)),
                            child: const Text('Disconnect'),
                          )
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: settings.hasSeerr
                        ? null
                        : () => showDialog<void>(
                              context: context,
                              builder: (_) => const _SeerrDialog(),
                            ),
                  ),
                ]),
                const _Heading('Appearance'),
                _Card(children: [
                  _Choice<String>(
                    title: 'TV layout',
                    subtitle: 'Larger artwork and remote-friendly focus.',
                    value: settings.tvMode,
                    options: const [
                      ('auto', 'Automatic'),
                      ('on', 'Always'),
                      ('off', 'Never'),
                    ],
                    onChanged: (v) =>
                        notifier.change((s) => s.copyWith(tvMode: v)),
                  ),
                  SwitchListTile(
                    title: const Text('True black background'),
                    subtitle: const Text('Best on OLED screens'),
                    value: settings.trueBlack,
                    onChanged: (v) =>
                        notifier.change((s) => s.copyWith(trueBlack: v)),
                  ),
                ]),
                const SizedBox(height: 24),
                const Center(
                  child: Text(
                    '${ClientInfo.product} ${ClientInfo.version}',
                    style: TextStyle(color: Palette.muted, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(
      BuildContext context, WidgetRef ref, ServerConfig s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${s.name}?'),
        content: const Text(
            'This signs the app out of the server. Nothing on the server '
            'changes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(serversProvider.notifier).remove(s.id);
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 28, 4, 10),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 12,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w800,
            color: Palette.muted,
          ),
        ),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
        color: Palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Palette.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      );
}

class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final current = options
            .where((o) => o.$1 == value)
            .map((o) => o.$2)
            .firstOrNull ??
        options.first.$2;
    return SelectMenu(
      alignmentOffset: const Offset(16, 0),
      items: [
        for (final (v, label) in options)
          SelectMenuItem(
            label: label,
            selected: v == value,
            icon: v == value ? Icons.check_rounded : null,
            onPressed: () => onChanged(v),
          ),
      ],
      builder: (context, focusNode, toggle) => ListTile(
        focusNode: focusNode,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(current,
                style: const TextStyle(
                    color: Palette.text, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            const Icon(Icons.unfold_more_rounded, size: 18),
          ],
        ),
        onTap: toggle,
      ),
    );
  }
}

class _SeerrDialog extends ConsumerStatefulWidget {
  const _SeerrDialog();

  @override
  ConsumerState<_SeerrDialog> createState() => _SeerrDialogState();
}

class _SeerrDialogState extends ConsumerState<_SeerrDialog> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _secret = TextEditingController();
  String _mode = 'key';
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _secret.dispose();
    super.dispose();
  }

  String? get _plexToken => ref
      .read(serversProvider)
      .map((s) => s.accountToken)
      .nonNulls
      .firstOrNull;

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final url = _url.text.trim();
      if (url.isEmpty) throw const FormatException('Enter the Seerr address');
      String? key, cookie;
      switch (_mode) {
        case 'key':
          key = _secret.text.trim();
        case 'plex':
          cookie = await SeerrClient.signIn(url,
              mode: 'plex', secret: _plexToken ?? '');
        default:
          cookie = await SeerrClient.signIn(url,
              mode: _mode, user: _user.text.trim(), secret: _secret.text);
      }
      // Prove the credentials work before saving them.
      final probe = SeerrClient(url, apiKey: key, cookie: cookie);
      try {
        await probe.whoAmI();
      } finally {
        probe.close();
      }
      ref.read(settingsProvider.notifier).change((s) =>
          s.copyWith(seerrUrl: url, seerrApiKey: key, seerrCookie: cookie));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPlex = _plexToken != null;
    return AlertDialog(
      title: const Text('Connect Seerr'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _url,
                autofocus: true,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                    hintText: 'Address, e.g. 192.168.1.20:5055'),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (id, label) in [
                    ('key', 'API key'),
                    if (hasPlex) ('plex', 'My Plex account'),
                    ('jellyfin', 'Jellyfin login'),
                    ('local', 'Email login'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _mode == id,
                      onSelected: (_) => setState(() => _mode = id),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              if (_mode == 'jellyfin' || _mode == 'local') ...[
                TextField(
                  controller: _user,
                  autocorrect: false,
                  decoration: InputDecoration(
                      hintText: _mode == 'local' ? 'Email' : 'Username'),
                ),
                const SizedBox(height: 10),
              ],
              if (_mode != 'plex')
                TextField(
                  controller: _secret,
                  obscureText: true,
                  decoration: InputDecoration(
                      hintText: _mode == 'key' ? 'API key' : 'Password'),
                  onSubmitted: (_) => _connect(),
                )
              else
                const Text(
                  'Signs in to Seerr with the Plex account already linked '
                  'to this app.',
                  style: TextStyle(color: Palette.muted),
                ),
              if (_mode == 'key')
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Found in Seerr under Settings → General. Requests made '
                    'with the API key are filed as the admin user.',
                    style: TextStyle(color: Palette.muted, fontSize: 12.5),
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
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: Text(_busy ? 'Connecting…' : 'Connect'),
        ),
      ],
    );
  }
}

/// The libraries on one server: show or hide each across the app, and ask
/// the server to scan for new files.
class _ServerLibraries extends ConsumerStatefulWidget {
  const _ServerLibraries({required this.server});
  final ServerConfig server;

  @override
  ConsumerState<_ServerLibraries> createState() => _ServerLibrariesState();
}

class _ServerLibrariesState extends ConsumerState<_ServerLibraries> {
  /// Library ids with a scan request in flight; '*' is "scan all".
  final _scanning = <String>{};

  String get _serverId => widget.server.id;

  Future<void> _scan(Library? library) async {
    final key = library?.id ?? '*';
    setState(() => _scanning.add(key));
    final messenger = ScaffoldMessenger.of(context);
    final what = library?.title ?? 'all libraries';
    try {
      await scanLibrary(
          ProviderScope.containerOf(context, listen: false), _serverId, library);
      messenger.showSnackBar(SnackBar(
        content: Text('Scanning $what on ${widget.server.name}. New items '
            'appear once the server finishes.'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _scanning.remove(key));
    }
  }

  Widget _scanButton(Library library) {
    final busy = _scanning.contains(library.id);
    return IconButton(
      tooltip: 'Scan ${library.title}',
      onPressed: busy ? null : () => _scan(library),
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.sync_rounded),
    );
  }

  @override
  Widget build(BuildContext context) {
    final libs = ref.watch(allLibrariesProvider(_serverId));
    final hidden =
        ref.watch(settingsProvider.select((s) => s.hiddenOn(_serverId)));
    final canScan =
        ref.watch(backendsProvider)[_serverId]?.canScanLibraries ?? false;
    final list = libs.value;

    final subtitle = switch (libs) {
      AsyncData(:final value) => value.isEmpty
          ? 'No libraries'
          : '${value.where((l) => !hidden.contains(l.id)).length} of '
              '${value.length} shown',
      AsyncError() => 'Couldn\'t load libraries',
      _ => 'Loading…',
    };

    return ExpansionTile(
      // Keyed per server so expansion state doesn't jump between servers
      // when one is removed.
      key: PageStorageKey('libraries-$_serverId'),
      tilePadding: const EdgeInsets.only(left: 16, right: 12),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      shape: const Border(),
      collapsedShape: const Border(),
      leading: const Icon(Icons.video_library_outlined, color: Palette.muted),
      title: const Text('Libraries'),
      subtitle: Text(subtitle),
      children: [
        if (libs case AsyncError(:final error))
          ListTile(
            title: Text(friendlyError(error)),
            trailing: TextButton(
              onPressed: () => ref.invalidate(allLibrariesProvider(_serverId)),
              child: const Text('Retry'),
            ),
          )
        else if (list == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else ...[
          for (final lib in list)
            Builder(builder: (context) {
              final shown = !hidden.contains(lib.id);
              void toggle() => ref
                  .read(settingsProvider.notifier)
                  .setLibraryHidden(_serverId, lib.id, shown);
              return ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 12),
                leading: Icon(libraryIcon(lib.kind),
                    color: shown ? Palette.text : Palette.muted),
                title: Text(
                  lib.title,
                  style: TextStyle(color: shown ? null : Palette.muted),
                ),
                subtitle: shown ? null : const Text('Hidden'),
                onTap: toggle,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (canScan) _scanButton(lib),
                    Switch(
                      value: shown,
                      onChanged: (_) => toggle(),
                    ),
                  ],
                ),
              );
            }),
          if (canScan && list.length > 1)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _scanning.contains('*') ? null : () => _scan(null),
                  icon: _scanning.contains('*')
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('Scan all libraries'),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
