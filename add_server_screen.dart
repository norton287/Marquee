import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/demo.dart';
import '../core/jellyfin.dart';
import '../core/models.dart';
import '../core/plex.dart';
import '../core/providers.dart';
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
// Plex: link code, then pick servers
// ---------------------------------------------------------------------------

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
  PlexPin? _pin;
  Timer? _poll;
  int _polls = 0;
  String? _token;
  String? _user;
  List<_FoundServer>? _servers;
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
    super.dispose();
  }

  Future<void> _start() async {
    _poll?.cancel();
    setState(() {
      _pin = null;
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
      setState(() => _token = token);
      await _discover(token);
    } catch (_) {
      // Transient network errors: keep polling.
    }
  }

  Future<void> _discover(String token) async {
    try {
      final user = await PlexAccount.userName(token);
      final resources = await PlexAccount.servers(token);
      final found = await Future.wait(resources.map((r) async => _FoundServer(
          r, await PlexAccount.bestConnection(r.connections, r.accessToken))));
      for (final f in found) {
        f.selected = f.url != null;
      }
      if (!mounted) return;
      setState(() {
        _user = user;
        _servers = found;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _add() async {
    final notifier = ref.read(serversProvider.notifier);
    for (final f in _servers!.where((f) => f.selected && f.url != null)) {
      await notifier.add(ServerConfig(
        id: 'plex-${f.resource.machineId}',
        kind: ServerKind.plex,
        name: f.resource.name,
        baseUrl: f.url!,
        token: f.resource.accessToken,
        accountToken: _token,
        userName: _user,
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

    if (servers != null) {
      final any = servers.any((f) => f.selected && f.url != null);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Signed in as $_user', style: theme.textTheme.titleLarge),
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

    if (_token != null && _error == null) {
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
          TextField(
            controller: _address,
            autofocus: true,
            autocorrect: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            decoration: const InputDecoration(
              hintText: '192.168.1.20:8096 or jellyfin.example.com',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
            onSubmitted: (_) => _locate(),
          ),
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
          TextField(
            controller: _user,
            autofocus: true,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
            decoration: const InputDecoration(
              hintText: 'Username',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _password,
            obscureText: true,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            decoration: const InputDecoration(
              hintText: 'Password',
              prefixIcon: Icon(Icons.lock_outline),
            ),
            onSubmitted: (_) => _signIn(),
          ),
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
