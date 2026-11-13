import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'add_server_screen.dart';
import 'music.dart';
import 'theme.dart';
import 'widgets.dart';

class _Dest {
  const _Dest(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const _destinations = [
  _Dest('Home', Icons.home_outlined, Icons.home_rounded),
  _Dest('Libraries', Icons.video_library_outlined, Icons.video_library_rounded),
  _Dest('Search', Icons.search_rounded, Icons.search_rounded),
  _Dest('Explore', Icons.explore_outlined, Icons.explore_rounded),
  _Dest('Settings', Icons.settings_outlined, Icons.settings_rounded),
];

/// Bottom bar on phones; a side rail on tablets, desktops and TVs.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  StatefulNavigationShell get shell => widget.shell;

  /// Parent of everything in the side rail, to tell rail focus from page focus.
  final _navArea = FocusNode(
      debugLabel: 'side nav', canRequestFocus: false, skipTraversal: true);
  final _navItems = [
    for (final d in _destinations) FocusNode(debugLabel: 'nav ${d.label}'),
  ];

  /// Where focus was in each tab when the user moved into the rail, so
  /// pressing right goes back to the same card.
  final _lastInTab = <int, FocusNode>{};

  @override
  void dispose() {
    _navArea.dispose();
    for (final n in _navItems) {
      n.dispose();
    }
    super.dispose();
  }

  void _go(int i) =>
      shell.goBranch(i, initialLocation: i == shell.currentIndex);

  bool _inNav(FocusNode node) =>
      node == _navArea || node.ancestors.contains(_navArea);

  /// Arrow keys with a remote. Each page lives in its own route focus scope
  /// that stops at its edges, so the default traversal can never leave the
  /// page for the rail. Run the default first; when it finds nothing to the
  /// left, step into the rail ourselves.
  void _onDirection(DirectionalFocusIntent intent) {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return;
    final dir = intent.direction;
    if (_inNav(node)) {
      if (dir == TraversalDirection.right) {
        final back = _lastInTab[shell.currentIndex];
        if (back != null && back.context != null && back.canRequestFocus) {
          back.requestFocus();
          return;
        }
      }
      node.focusInDirection(dir);
      return;
    }
    if (node.focusInDirection(dir)) return;
    if (dir == TraversalDirection.left) {
      _lastInTab[shell.currentIndex] = node;
      _navItems[shell.currentIndex].requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLayout.of(context);
    final body = Column(
      children: [
        Expanded(child: shell),
        const MiniPlayer(),
      ],
    );
    if (!l.sideNav) {
      return Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: shell.currentIndex,
          onDestinationSelected: _go,
          destinations: [
            for (final d in _destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon, color: Palette.accent),
                label: d.label,
              ),
          ],
        ),
      );
    }
    final expanded = l.width >= 1360 && !l.tv;
    return Scaffold(
      body: SafeArea(
        child: Actions(
          actions: {
            DirectionalFocusIntent: _DirectionalAction(_onDirection),
          },
          child: Row(
            children: [
              Focus(
                focusNode: _navArea,
                child: FocusTraversalGroup(
                  child: _SideNav(
                    index: shell.currentIndex,
                    expanded: expanded,
                    tv: l.tv,
                    onSelect: _go,
                    focusNodes: _navItems,
                  ),
                ),
              ),
              Expanded(child: FocusTraversalGroup(child: body)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Same as Flutter's DirectionalFocusAction (arrow keys still move the
/// cursor inside text fields), but routed through [AppShell]'s handler.
class _DirectionalAction extends Action<DirectionalFocusIntent> {
  _DirectionalAction(this.onInvoke);
  final void Function(DirectionalFocusIntent) onInvoke;

  @override
  void invoke(DirectionalFocusIntent intent) {
    final inText =
        FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    if (intent.ignoreTextFields && inText) return;
    onInvoke(intent);
  }
}

class _SideNav extends ConsumerWidget {
  const _SideNav({
    required this.index,
    required this.expanded,
    required this.tv,
    required this.onSelect,
    required this.focusNodes,
  });
  final int index;
  final bool expanded;
  final bool tv;
  final ValueChanged<int> onSelect;
  final List<FocusNode> focusNodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plexServer = ref
        .watch(serversProvider)
        .where((s) =>
            s.kind == ServerKind.plex &&
            (s.homeToken ?? s.accountToken) != null)
        .firstOrNull;
    return Container(
      width: expanded ? 216 : (tv ? AppLayout.tvRailWidth : 84),
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: Palette.outline)),
      ),
      padding: EdgeInsets.symmetric(horizontal: expanded ? 14 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 22),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: expanded ? 10 : 0),
            child: expanded
                ? const Wordmark()
                : const Center(child: Wordmark(compact: true)),
          ),
          const SizedBox(height: 26),
          for (var i = 0; i < _destinations.length; i++) ...[
            if (i == _destinations.length - 1) ...[
              const Spacer(),
              if (plexServer != null) ...[
                _SideProfileItem(
                  server: plexServer,
                  expanded: expanded,
                  onTap: () =>
                      showPlexProfileDialog(context, ref, server: plexServer),
                ),
                const SizedBox(height: 6),
              ],
            ],
            _SideItem(
              dest: _destinations[i],
              selected: i == index,
              expanded: expanded,
              focusNode: focusNodes[i],
              onTap: () => onSelect(i),
            ),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _SideProfileItem extends StatelessWidget {
  const _SideProfileItem({
    required this.server,
    required this.expanded,
    required this.onTap,
  });
  final ServerConfig server;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = server.userName ?? 'Profile';
    return Semantics(
      button: true,
      label: 'Switch Plex profile ($name)',
      child: Pressable(
        onTap: onTap,
        grow: 1,
        builder: (context, focused, hovered) {
          final color = focused ? Palette.text : Palette.muted;
          final avatar =
              PlexAvatar(name: name, thumb: server.userThumb, size: 24);
          return AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: EdgeInsets.symmetric(
                vertical: expanded ? 11 : 9, horizontal: expanded ? 12 : 2),
            decoration: BoxDecoration(
              color: focused
                  ? Palette.surfaceHigh
                  : (hovered ? Palette.surface : null),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: focused ? Colors.white : Colors.transparent, width: 2),
            ),
            child: expanded
                ? Row(children: [
                    avatar,
                    const SizedBox(width: 14),
                    Flexible(
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: color, fontWeight: FontWeight.w600)),
                    ),
                  ])
                : Column(children: [
                    avatar,
                    const SizedBox(height: 3),
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: color,
                            fontWeight: FontWeight.w600)),
                  ]),
          );
        },
      ),
    );
  }
}

class _SideItem extends StatelessWidget {
  const _SideItem({
    required this.dest,
    required this.selected,
    required this.expanded,
    required this.focusNode,
    required this.onTap,
  });
  final _Dest dest;
  final bool selected;
  final bool expanded;
  final FocusNode focusNode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: dest.label,
      child: Pressable(
        focusNode: focusNode,
        onTap: onTap,
        grow: 1,
        builder: (context, focused, hovered) {
          final color = selected || focused ? Palette.text : Palette.muted;
          final icon = Icon(selected ? dest.selectedIcon : dest.icon,
              color: selected ? Palette.accent : color, size: 24);
          return AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: EdgeInsets.symmetric(
                vertical: expanded ? 11 : 9, horizontal: expanded ? 12 : 2),
            decoration: BoxDecoration(
              color: focused
                  ? Palette.surfaceHigh
                  : (selected || hovered ? Palette.surface : null),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: focused ? Colors.white : Colors.transparent,
                  width: 2),
            ),
            child: expanded
                ? Row(children: [
                    icon,
                    const SizedBox(width: 14),
                    Flexible(
                      child: Text(dest.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: color, fontWeight: FontWeight.w600)),
                    ),
                  ])
                : Column(children: [
                    icon,
                    const SizedBox(height: 3),
                    Text(dest.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: color,
                            fontWeight: FontWeight.w600)),
                  ]),
          );
        },
      ),
    );
  }
}

class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.compact = false, this.size = 20});
  final bool compact;
  final double size;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: size * 1.5,
      height: size * 1.5,
      decoration: BoxDecoration(
        color: Palette.accent,
        borderRadius: BorderRadius.circular(size * 0.45),
      ),
      child: Icon(Icons.play_arrow_rounded,
          color: Palette.onAccent, size: size * 1.2),
    );
    if (compact) return mark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        SizedBox(width: size * 0.5),
        Flexible(
          child: Text(
            'Marquee',
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
        ),
      ],
    );
  }
}
