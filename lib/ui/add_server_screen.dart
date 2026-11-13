import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/demo.dart';
import '../core/jellyfin.dart';
import '../core/models.dart';
import '../core/plex.dart';
import '../core/providers.dart';
import 'music.dart';
import 'phone_input.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

const demoServer = ServerConfig(
  id: DemoBackend.demoId,
  kind: ServerKind.demo,
  name: 'Demo library',
  baseUrl: 'demo://',
);

/// First run: pick what to connect.
class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = AppLayout.of(context).tv;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Align(
                    alignment: Alignment.centerLeft,
                    child: Wordmark(size: 26)),
                const SizedBox(height: 28),
                Text('Your library,\non every screen.',
                    style: Theme.of(context)
                        .textTheme
                        .displaySmall
                        ?.copyWith(height: 1.05)),
                const SizedBox(height: 12),
                const Text(
                  'Connect a Plex or Jellyfin server to start watching. '
                  'You can add more servers later.',
                  style: TextStyle(color: Palette.muted, fontSize: 15),
                ),
                const SizedBox(height: 28),
                FilledButton(
                  autofocus: tv,
                  onPressed: () => context.push('/add-server?kind=plex'),
                  child: const Text('Connect Plex'),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: () => context.push('/add-server?kind=jellyfin'),
                  child: const Text('Connect Jellyfin'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () =>
                      ref.read(serversProvider.notifier).add(demoServer),
                  child: const Text('Look around with a demo library'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AddServerScreen extends StatelessWidget {
  const AddServerScreen({super.key, required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    void done() => context.canPop() ? context.pop() : context.go('/home');
    return Scaffold(
      appBar: AppBar(
        title: Text(kind == 'plex' ? 'Connect Plex' : 'Connect Jellyfin'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: kind == 'plex'
                ? _PlexFlow(onDone: done)
                : _JellyfinFlow(onDone: done),
          ),
        ),
      ),
    );
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.error);
  final Object? error;

  @override
  Widget build(BuildContext context) {
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(friendlyError(error!),
          style: TextStyle(color: Theme.of(context).colorScheme.error)),
    );
  }
}

// ---------------------------------------------------------------------------
// Plex: link code, pick Home profile (if any), then pick servers
// ---------------------------------------------------------------------------

class PlexAvatar extends StatelessWidget {
  const PlexAvatar({
    super.key,
    required this.name,
    this.thumb,
    this.size = 36,
  });

  final String name;
  final String? thumb;
  final double size;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? 'P' : trimmed[0].toUpperCase();
    final hue = (name.hashCode % 360).abs().toDouble();
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: HSLColor.fromAHSL(1, hue, 0.35, 0.28).toColor(),
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.44,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
    final url = thumb;
    if (url == null || url.isEmpty || !Artwork.network) return fallback;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          placeholder: (_, _) => fallback,
          errorWidget: (_, _, _) => fallback,
        ),
      ),
    );
  }
}

/// Opens the "Who's watching?" dialog to switch the active Plex Home profile.
/// Without [server] (the Home button, the rail), several signed-in Plex
/// accounts are first offered in "Which Plex account?".
Future<void> showPlexProfileDialog(
  BuildContext context,
  WidgetRef ref, {
  ServerConfig? server,
}) async {
  var target = server;
  if (target == null) {
    final accounts = plexAccounts(ref.read(serversProvider));
    if (accounts.length > 1) {
      final current = profileServer(
          ref.read(serversProvider), ref.read(settingsProvider).profileServerId);
      target = await showDialog<ServerConfig>(
        context: context,
        builder: (_) => _PlexAccountDialog(accounts: accounts, current: current),
      );
      if (target == null) return;
    } else {
      target = accounts.firstOrNull?.first;
    }
  }
  if (target == null || !context.mounted) return;
  final homeToken = target.homeToken ?? target.accountToken;
  if (homeToken == null || homeToken.isEmpty) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _PlexProfileDialog(server: target!, homeToken: homeToken),
  );
}

/// One row per signed-in Plex account; returns a server of the chosen one.
class _PlexAccountDialog extends StatelessWidget {
  const _PlexAccountDialog({required this.accounts, required this.current});
  final List<List<ServerConfig>> accounts;
  final ServerConfig? current;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Which Plex account?'),
      contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final g in accounts)
              ListTile(
                // The account in use (the remote starts there).
                autofocus: g.any((s) => s.id == current?.id),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                focusColor: Palette.surfaceHigh,
                leading: PlexAvatar(
                    name: g.first.userName ?? g.first.name,
                    thumb: g.first.userThumb),
                title: Text(g.first.userName ?? 'Plex account'),
                subtitle: Text('Plex · ${g.map((s) => s.name).join(', ')}'),
                onTap: () => Navigator.pop(context, g.first),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _PlexProfileDialog extends ConsumerStatefulWidget {
  const _PlexProfileDialog({
    required this.server,
    required this.homeToken,
  });

  final ServerConfig server;
  final String homeToken;

  @override
  ConsumerState<_PlexProfileDialog> createState() => _PlexProfileDialogState();
}

class _PlexProfileDialogState extends ConsumerState<_PlexProfileDialog> {
  List<PlexHomeUser>? _users;
  PlexHomeUser? _pinTarget;
  final _pinController = TextEditingController();
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _users = null;
    });
    try {
      final users = await PlexAccount.homeUsers(widget.homeToken);
      if (!mounted) return;
      setState(() => _users = users);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _pick(PlexHomeUser u, {String? pin}) async {
    if (u.protected && (pin == null || pin.isEmpty)) {
      setState(() {
        _pinTarget = u;
        _pinController.clear();
        _error = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Everything the steps after the switch need is read now: Back can
      // close this dialog while switching, and `ref` dies with it.
      final settings = ref.read(settingsProvider.notifier);
      final music = ref.read(musicProvider.notifier);
      final queue = ref.read(musicProvider).queue;
      final serverId = widget.server.id;
      final switched = {
        for (final g in plexAccounts(ref.read(serversProvider)))
          if (g.any((s) => s.id == serverId)) ...g.map((s) => s.id),
      };
      await ref.read(serversProvider.notifier).switchPlexProfile(
            homeToken: widget.homeToken,
            user: u,
            pin: pin,
          );
      // The Home button now shows this account.
      settings.change((s) => s.copyWith(profileServerId: serverId));
      // Queued music from these servers streams with the old profile's
      // token: stop it rather than keep playing as someone else.
      if (musicFromServers(queue, switched)) await music.stop();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pinTarget = _pinTarget;
    final users = _users;
    final activeId = widget.server.userId;
    final activeName = widget.server.userName;

    return AlertDialog(
      title: Text(pinTarget != null ? 'Enter PIN' : 'Who\'s watching?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, minWidth: 280),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (pinTarget != null) ...[
                Row(
                  children: [
                    PlexAvatar(
                        name: pinTarget.name, thumb: pinTarget.thumb, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(pinTarget.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          Text(pinTarget.subtitle,
                              style: const TextStyle(
                                  color: Palette.muted, fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _pinController,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  maxLength: 4,
                  decoration: const InputDecoration(
                    hintText: '4-digit PIN',
                    prefixIcon: Icon(Icons.lock_outline_rounded),
                    counterText: '',
                  ),
                  onSubmitted: (v) => _pick(pinTarget, pin: v.trim()),
                ),
              ] else if (users == null && _error == null) ...[
                const SizedBox(height: 120, child: Loading()),
              ] else if (users != null) ...[
                for (var i = 0; i < users.length; i++) ...[
                  Builder(builder: (context) {
                    final u = users[i];
                    final isCurrent = (activeId != null && activeId.isNotEmpty)
                        ? u.uuid == activeId
                        : u.name == activeName;
                    return ListTile(
                      autofocus: isCurrent || (activeId == null && i == 0),
                      enabled: !_busy,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      leading: PlexAvatar(
                          name: u.name, thumb: u.thumb, size: 40),
                      title: Text(u.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(u.subtitle),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (u.protected)
                            const Padding(
                              padding: EdgeInsets.only(right: 6),
                              child: Icon(Icons.lock_outline_rounded,
                                  size: 18, color: Palette.muted),
                            ),
                          if (isCurrent)
                            const Icon(Icons.check_circle_rounded,
                                size: 20, color: Palette.accent),
                        ],
                      ),
                      onTap: _busy ? null : () => _pick(u),
                    );
                  }),
                ],
              ],
              _ErrorText(_error),
            ],
          ),
        ),
      ),
      actions: [
        if (pinTarget != null) ...[
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _pinTarget = null;
                      _error = null;
                    }),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _pick(pinTarget, pin: _pinController.text.trim()),
            child: Text(_busy ? 'Switching…' : 'Continue'),
          ),
        ] else ...[
          if (_error != null && users == null)
            TextButton(onPressed: _load, child: const Text('Retry')),
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ],
    );
  }
}

class _PlexFlow extends ConsumerStatefulWidget {
  const _PlexFlow({required this.onDone});
  final VoidCallback onDone;

  @override
  ConsumerState<_PlexFlow> createState() => _PlexFlowState();
}

class _FoundServer {
  _FoundServer(this.resource, this.url);
  final PlexResource resource;
  final String? url;
  bool selected = true;
}

class _PlexFlowState extends ConsumerState<_PlexFlow> {
  final _profilePinController = TextEditingController();
  PlexPin? _pin;
  Timer? _poll;
  int _polls = 0;
  String? _homeToken;
  String? _accountToken;
  List<PlexHomeUser>? _homeUsers;
  PlexHomeUser? _selectedUser;
  PlexHomeUser? _pinTarget;
  List<_FoundServer>? _servers;
  bool _busy = false;
  Object? _error;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _profilePinController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    _poll?.cancel();
    setState(() {
      _pin = null;
      _homeToken = null;
      _accountToken = null;
      _homeUsers = null;
      _selectedUser = null;
      _pinTarget = null;
      _servers = null;
      _busy = false;
      _error = null;
      _expired = false;
      _polls = 0;
    });
    try {
      // Short codes work everywhere: typed at plex.tv/link on a TV, or
      // carried in the sign-in link on a phone or computer.
      final pin = await PlexAccount.createPin(strong: false);
      if (!mounted) return;
      setState(() => _pin = pin);
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _check() async {
    final pin = _pin;
    if (pin == null) return;
    if (++_polls > 150) {
      _poll?.cancel();
      setState(() => _expired = true);
      return;
    }
    try {
      final token = await PlexAccount.checkPin(pin);
      if (token == null || !mounted) return;
      _poll?.cancel();
      setState(() => _homeToken = token);
      await _loadProfiles(token);
    } catch (_) {
      // Transient network errors: keep polling.
    }
  }

  Future<void> _loadProfiles(String homeToken) async {
    try {
      final users = await PlexAccount.homeUsers(homeToken);
      if (!mounted) return;
      setState(() => _homeUsers = users);
      if (users.length == 1 && !users.first.protected) {
        await _selectProfile(users.first, switchToken: false);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _selectProfile(
    PlexHomeUser user, {
    String? pin,
    bool switchToken = true,
  }) async {
    if (user.protected && (pin == null || pin.isEmpty)) {
      setState(() {
        _pinTarget = user;
        _profilePinController.clear();
        _error = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final homeToken = _homeToken!;
      final activeToken = switchToken
          ? await PlexAccount.switchHomeUser(homeToken, user.uuid, pin: pin)
          : homeToken;
      final resources = await PlexAccount.servers(activeToken);
      final found = await Future.wait(resources.map((r) async => _FoundServer(
          r, await PlexAccount.bestConnection(r.connections, r.accessToken))));
      for (final f in found) {
        f.selected = f.url != null;
      }
      if (!mounted) return;
      setState(() {
        _selectedUser = user;
        _accountToken = activeToken;
        _pinTarget = null;
        _servers = found;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final notifier = ref.read(serversProvider.notifier);
    final user = _selectedUser;
    for (final f in _servers!.where((f) => f.selected && f.url != null)) {
      await notifier.add(ServerConfig(
        id: 'plex-${f.resource.machineId}',
        kind: ServerKind.plex,
        name: f.resource.name,
        baseUrl: f.url!,
        token: f.resource.accessToken,
        accountToken: _accountToken ?? _homeToken,
        homeToken: _homeToken,
        userId: user?.uuid,
        userName: user?.name,
        userThumb: user?.thumb,
        machineId: f.resource.machineId,
        connections: f.resource.connections,
      ));
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tv = AppLayout.of(context).tv;
    final servers = _servers;
    final homeUsers = _homeUsers;
    final pinTarget = _pinTarget;
    final user = _selectedUser;

    if (servers != null && user != null) {
      final any = servers.any((f) => f.selected && f.url != null);
      final canSwitchProfile = (homeUsers?.length ?? 0) > 1;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PlexAvatar(name: user.name, thumb: user.thumb, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Signed in as ${user.name}',
                    style: theme.textTheme.titleLarge),
              ),
              if (canSwitchProfile)
                TextButton.icon(
                  onPressed: () => setState(() {
                    _servers = null;
                    _selectedUser = null;
                    _error = null;
                  }),
                  icon: const Icon(Icons.switch_account_rounded, size: 18),
                  label: const Text('Switch profile'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            servers.isEmpty
                ? 'This account has no Plex Media Server. Set one up or ask '
                    'a friend to share theirs, then try again.'
                : 'Choose the servers to add.',
            style: const TextStyle(color: Palette.muted),
          ),
          const SizedBox(height: 12),
          for (final f in servers)
            CheckboxListTile(
              value: f.selected,
              enabled: f.url != null,
              contentPadding: EdgeInsets.zero,
              onChanged: (v) => setState(() => f.selected = v ?? false),
              title: Text(f.resource.name),
              subtitle: Text(
                f.url == null
                    ? 'Not reachable from this network right now'
                    : (f.resource.owned ? 'Your server' : 'Shared with you'),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            autofocus: true,
            onPressed: any ? _add : null,
            child: const Text('Add'),
          ),
        ],
      );
    }

    if (pinTarget != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Enter PIN for ${pinTarget.name}',
              style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'This Plex Home profile is protected with a 4-digit PIN.',
            style: TextStyle(color: Palette.muted),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _profilePinController,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            maxLength: 4,
            decoration: const InputDecoration(
              hintText: '4-digit PIN',
              prefixIcon: Icon(Icons.lock_outline_rounded),
              counterText: '',
            ),
            onSubmitted: (v) => _selectProfile(pinTarget, pin: v.trim()),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _selectProfile(pinTarget,
                    pin: _profilePinController.text.trim()),
            child: Text(_busy ? 'Checking…' : 'Continue'),
          ),
          if ((homeUsers?.length ?? 0) > 1) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _pinTarget = null;
                        _error = null;
                      }),
              child: const Text('Choose a different profile'),
            ),
          ],
          _ErrorText(_error),
        ],
      );
    }

    if (homeUsers != null &&
        _selectedUser == null &&
        (homeUsers.length > 1 || homeUsers.first.protected)) {
      if (_busy) {
        return const Column(
          children: [
            Loading(),
            SizedBox(height: 16),
            Text('Finding your servers…'),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Who\'s watching?', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'Choose the Plex Home profile to use on this device. You can '
            'switch profiles anytime.',
            style: TextStyle(color: Palette.muted),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: Palette.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Palette.outline),
            ),
            child: Column(
              children: [
                for (var i = 0; i < homeUsers.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    autofocus: i == 0,
                    leading: PlexAvatar(
                      name: homeUsers[i].name,
                      thumb: homeUsers[i].thumb,
                      size: 40,
                    ),
                    title: Text(homeUsers[i].name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(homeUsers[i].subtitle),
                    trailing: homeUsers[i].protected
                        ? const Icon(Icons.lock_outline_rounded,
                            size: 18, color: Palette.muted)
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: () => _selectProfile(homeUsers[i]),
                  ),
                ],
              ],
            ),
          ),
          _ErrorText(_error),
        ],
      );
    }

    if (_homeToken != null && _error == null) {
      return const Column(
        children: [
          Loading(),
          SizedBox(height: 16),
          Text('Finding your servers…'),
        ],
      );
    }

    final pin = _pin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Link your Plex account', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          tv
              ? 'On your phone or computer, go to plex.tv/link and enter '
                  'this code.'
              : 'Sign in on plex.tv. This screen continues by itself once '
                  'you approve.',
          style: const TextStyle(color: Palette.muted),
        ),
        const SizedBox(height: 24),
        if (pin == null && _error == null)
          const SizedBox(height: 90, child: Loading())
        else if (pin != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            decoration: BoxDecoration(
              color: Palette.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Palette.outline),
            ),
            child: Column(
              children: [
                const Text('plex.tv/link',
                    style: TextStyle(color: Palette.muted)),
                const SizedBox(height: 6),
                SelectableText(
                  pin.code.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 44,
                    letterSpacing: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (!tv)
            FilledButton.icon(
              onPressed: () => launchUrl(Uri.parse(pin.authUrl),
                  mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('Open the Plex sign-in page'),
            ),
          const SizedBox(height: 16),
          if (_expired)
            OutlinedButton(
                onPressed: _start, child: const Text('Get a new code'))
          else
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('Waiting for approval…',
                    style: TextStyle(color: Palette.muted)),
              ],
            ),
        ],
        _ErrorText(_error),
        if (_error != null) ...[
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _start, child: const Text('Try again')),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Jellyfin: address, then password or Quick Connect
// ---------------------------------------------------------------------------

class _JellyfinFlow extends ConsumerStatefulWidget {
  const _JellyfinFlow({required this.onDone});
  final VoidCallback onDone;

  @override
  ConsumerState<_JellyfinFlow> createState() => _JellyfinFlowState();
}

class _JellyfinFlowState extends ConsumerState<_JellyfinFlow> {
  final _address = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  JellyfinServerInfo? _server;
  bool _quickConnect = false;
  String? _code;
  Timer? _poll;
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _poll?.cancel();
    _address.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _locate() => _run(() async {
        final s = await JellyfinAuth.locate(_address.text);
        final qc = await JellyfinAuth.quickConnectEnabled(s);
        if (!mounted) return;
        setState(() {
          _server = s;
          _quickConnect = qc;
        });
      });

  Future<void> _finish(JellyfinLogin login) async {
    _poll?.cancel();
    await ref.read(serversProvider.notifier).add(ServerConfig(
          id: 'jf-${login.serverId}-${login.userId}',
          kind: ServerKind.jellyfin,
          name: login.serverName,
          baseUrl: login.baseUrl,
          token: login.token,
          userId: login.userId,
          userName: login.userName,
        ));
    widget.onDone();
  }

  Future<void> _signIn() => _run(() async {
        await _finish(await JellyfinAuth.byPassword(
            _server!, _user.text.trim(), _password.text));
      });

  Future<void> _startQuickConnect() => _run(() async {
        final server = _server!;
        final (secret, code) = await JellyfinAuth.quickConnectStart(server);
        if (!mounted) return;
        setState(() => _code = code);
        _poll?.cancel();
        _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
          try {
            final login = await JellyfinAuth.quickConnectPoll(server, secret);
            if (login != null && mounted) await _finish(login);
          } catch (_) {
            // Keep waiting; the code stays valid for a few minutes.
          }
        });
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final server = _server;

    if (server == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Where is your server?', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'Enter its address. The port is optional — the usual ones are '
            'tried for you.',
            style: TextStyle(color: Palette.muted),
          ),
          const SizedBox(height: 20),
          RemoteTextField(
            child: TextField(
            controller: _address,
            autofocus: true,
            autocorrect: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(
              hintText: '192.168.1.20:8096 or jellyfin.example.com',
              prefixIcon: const Icon(Icons.dns_outlined),
              suffixIcon: phoneTypeButton(context, _address,
                  label: 'Server address'),
            ),
            onSubmitted: (_) => _locate(),
          )),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _locate,
            child: Text(_busy ? 'Looking…' : 'Continue'),
          ),
          _ErrorText(_error),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(server.name, style: theme.textTheme.headlineSmall),
        Text('Jellyfin ${server.version} · ${server.baseUrl}',
            style: const TextStyle(color: Palette.muted, fontSize: 13)),
        const SizedBox(height: 20),
        if (_code != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            decoration: BoxDecoration(
              color: Palette.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Palette.outline),
            ),
            child: Column(
              children: [
                const Text('Quick Connect code',
                    style: TextStyle(color: Palette.muted)),
                const SizedBox(height: 6),
                SelectableText(
                  _code!,
                  style: const TextStyle(
                    fontSize: 40,
                    letterSpacing: 8,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'In a Jellyfin app where you are already signed in, open '
            'Settings → Quick Connect and enter this code.',
            style: TextStyle(color: Palette.muted),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () {
              _poll?.cancel();
              setState(() => _code = null);
            },
            child: const Text('Use a password instead'),
          ),
        ] else ...[
          RemoteTextField(
            child: TextField(
            controller: _user,
            autofocus: true,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
            decoration: InputDecoration(
              hintText: 'Username',
              prefixIcon: const Icon(Icons.person_outline),
              suffixIcon: phoneTypeButton(context, _user, label: 'Username'),
            ),
          )),
          const SizedBox(height: 10),
          RemoteTextField(
            child: TextField(
            controller: _password,
            obscureText: true,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(
              hintText: 'Password',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: phoneTypeButton(context, _password,
                  label: 'Password', obscure: true),
            ),
            onSubmitted: (_) => _signIn(),
          )),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _signIn,
            child: Text(_busy ? 'Signing in…' : 'Sign in'),
          ),
          if (_quickConnect) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _busy ? null : _startQuickConnect,
              child: const Text('Use Quick Connect'),
            ),
          ],
        ],
        _ErrorText(_error),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () {
            _poll?.cancel();
            setState(() {
              _server = null;
              _code = null;
              _error = null;
            });
          },
          child: const Text('Use a different server'),
        ),
      ],
    );
  }
}
