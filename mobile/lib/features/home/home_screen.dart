import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/app_lock.dart';
import '../../core/config.dart';
import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../chat/chat_screen.dart';
import '../chat/topics_screen.dart';
import '../contacts/contacts_screen.dart';
import '../search/search_screen.dart';
import '../stories/stories.dart';
import '../settings/downloads_screen.dart';
import '../settings/settings_screen.dart';
import 'chat_tile.dart';

/// Right-hand pane of the tablet split view; null on phones.
final chatPaneNavigatorKey = GlobalKey<NavigatorState>();

/// Width from which the chat list and the open chat are shown side by side.
const splitViewMinWidth = 840.0;

void openChat(BuildContext context, int chatId, {int? messageId}) {
  final account = ProviderScope.containerOf(context, listen: false).read(accountProvider);
  final chat = account.chats[chatId];
  final Widget screen = messageId == null && chat != null && account.isForum(chat)
      ? TopicsScreen(chatId: chatId)
      : ChatScreen(key: ValueKey('chat_${chatId}_$messageId'), chatId: chatId, initialMessageId: messageId);
  final pane = chatPaneNavigatorKey.currentState;
  if (pane != null && MediaQuery.sizeOf(context).width >= splitViewMinWidth) {
    pane.pushAndRemoveUntil(MaterialPageRoute<void>(builder: (_) => screen), (route) => route.isFirst);
    return;
  }
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(foldersProvider);
    final s = context.s;
    final tabs = <(String, String)>[
      ('main', s.t('all_chats')),
      if (ref.watch(settingsProvider.select((st) => st.chatTypeTabs)))
        for (final type in chatTypeTabs) (type, s.t('tab_${type.substring(5)}')),
      for (final folder in folders) ('folder:${folder.id}', folder.name.text.text),
    ];
    final list = DefaultTabController(
      key: ValueKey(tabs.map((t) => t.$1).join(',')),
      length: tabs.length,
      child: Scaffold(
        drawer: const HomeDrawer(),
        appBar: AppBar(
          title: const _ConnectionTitle(),
          actions: [
            IconButton(
              icon: const Icon(Icons.search_rounded),
              tooltip: s.t('search'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen())),
            ),
          ],
          bottom: tabs.length > 1
              ? TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  indicatorColor: Colors.white,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white70,
                  dividerColor: Colors.transparent,
                  tabs: [for (final tab in tabs) Tab(child: _FolderTabLabel(listKey: tab.$1, title: tab.$2))],
                )
              : null,
        ),
        body: TabBarView(
          children: [for (final tab in tabs) ChatListView(listKey: tab.$1, showArchive: tab.$1 == 'main')],
        ),
        floatingActionButton: FloatingActionButton(
          tooltip: s.t('new_message'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ContactsScreen(pickToChat: true))),
          child: const Icon(Icons.edit_rounded),
        ),
      ),
    );
    if (MediaQuery.sizeOf(context).width < splitViewMinWidth) return list;
    return Row(
      children: [
        SizedBox(width: 380, child: list),
        const VerticalDivider(width: 1),
        Expanded(
          child: Navigator(
            key: chatPaneNavigatorKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const _EmptyChatPane()),
          ),
        ),
      ],
    );
  }
}

class _EmptyChatPane extends StatelessWidget {
  const _EmptyChatPane();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/logo.png', width: 96, height: 96),
              const SizedBox(height: 16),
              Text(context.t('select_chat'), style: TextStyle(color: Theme.of(context).hintColor, fontSize: 16)),
            ],
          ),
        ),
      );
}

class _FolderTabLabel extends ConsumerWidget {
  const _FolderTabLabel({required this.listKey, required this.title});

  final String listKey;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadCountProvider(listKey));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title),
        if (unread > 0) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10)),
            child: Text(formatCount(unread), style: const TextStyle(fontSize: 12, color: Colors.white)),
          ),
        ],
      ],
    );
  }
}

class _ConnectionTitle extends ConsumerWidget {
  const _ConnectionTitle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(connectionStateProvider);
    final s = context.s;
    final text = switch (state) {
      td.ConnectionStateWaitingForNetwork() => s.t('waiting_network'),
      td.ConnectionStateConnecting() || td.ConnectionStateConnectingToProxy() => s.t('connecting'),
      td.ConnectionStateUpdating() => s.t('updating'),
      _ => null,
    };
    if (text == null) return const Text('Sado');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
        const SizedBox(width: 10),
        Text(text),
      ],
    );
  }
}

/// Scrollable chat list for one TDLib chat list; loads more chats on demand.
class ChatListView extends ConsumerStatefulWidget {
  const ChatListView({super.key, required this.listKey, this.showArchive = false});

  final String listKey;
  final bool showArchive;

  @override
  ConsumerState<ChatListView> createState() => _ChatListViewState();
}

class _ChatListViewState extends ConsumerState<ChatListView> with AutomaticKeepAliveClientMixin {
  bool _loading = false;

  @override
  bool get wantKeepAlive => true;

  td.ChatList get _list => chatListFromKey(widget.listKey);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
  }

  Future<void> _loadMore() async {
    if (_loading || !mounted) return;
    final account = ref.read(accountProvider);
    if (account.isListFullyLoaded(_list)) return;
    _loading = true;
    try {
      await account.loadChats(_list);
    } on TdException catch (error) {
      debugPrint('loadChats failed: $error');
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final chats = ref.watch(chatListProvider(widget.listKey));
    final archived = widget.showArchive ? ref.watch(chatListProvider('archive')) : const <td.Chat>[];
    final account = ref.watch(accountProvider);
    final s = context.s;
    if (chats.isEmpty && archived.isEmpty) {
      if (!account.isListFullyLoaded(_list)) return const Center(child: CircularProgressIndicator());
      return EmptyState(icon: Icons.forum_rounded, title: s.t('no_chats'), subtitle: s.t('no_chats_hint'));
    }
    final archiveRow = archived.isNotEmpty ? 1 : 0;
    final list = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 800) _loadMore();
        return false;
      },
      child: ListView.builder(
        itemCount: chats.length + archiveRow,
        itemExtent: 76,
        itemBuilder: (context, index) {
          if (archiveRow == 1 && index == 0) return _ArchiveTile(chats: archived);
          final chat = chats[index - archiveRow];
          return ChatTile(key: ValueKey(chat.id), chatId: chat.id, list: _list, onTap: () => openChat(context, chat.id));
        },
      ),
    );
    if (widget.listKey != 'main') return list;
    return Column(children: [const StoriesBar(), Expanded(child: list)]);
  }
}

class _ArchiveTile extends ConsumerWidget {
  const _ArchiveTile({required this.chats});

  final List<td.Chat> chats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final unread = chats.where((c) => c.unreadCount > 0).length;
    final names = chats.take(4).map((c) => chatTitle(c, account, s)).join(', ');
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ArchiveScreen())),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 14, 7),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: Theme.of(context).hintColor.withValues(alpha: 0.35),
              child: const Icon(Icons.archive_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(s.t('archive'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16.5)),
                  const SizedBox(height: 3),
                  Text(names, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).hintColor)),
                ],
              ),
            ),
            if (unread > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: Theme.of(context).hintColor, borderRadius: BorderRadius.circular(11)),
                child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 12.5)),
              ),
          ],
        ),
      ),
    );
  }
}

class ArchiveScreen extends StatelessWidget {
  const ArchiveScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.t('archive'))),
        body: const ChatListView(listKey: 'archive'),
      );
}

// ------------------------------------------------------------------ drawer

class HomeDrawer extends ConsumerStatefulWidget {
  const HomeDrawer({super.key});

  @override
  ConsumerState<HomeDrawer> createState() => _HomeDrawerState();
}

class _HomeDrawerState extends ConsumerState<HomeDrawer> {
  bool _showAccounts = false;

  void _push(Widget screen) {
    Navigator.of(context)
      ..pop()
      ..push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final slots = ref.watch(accountSlotsProvider);
    final settings = ref.watch(settingsProvider);
    final account = ref.watch(accountProvider);
    final s = context.s;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Container(
            color: theme.appBarTheme.backgroundColor,
            padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 16, 8, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (me != null) UserAvatar(userId: me.id, size: 64, showOnline: false),
                    const Spacer(),
                    IconButton(
                      icon: Icon(isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded, color: Colors.white),
                      onPressed: () => ref.read(settingsProvider.notifier).setThemeMode(isDark ? ThemeMode.light : ThemeMode.dark),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () => setState(() => _showAccounts = !_showAccounts),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              me == null ? '' : '${me.firstName} ${me.lastName}'.trim(),
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16),
                            ),
                            const SizedBox(height: 2),
                            Text(me == null ? '' : '+${me.phoneNumber}', style: const TextStyle(color: Colors.white70)),
                          ],
                        ),
                      ),
                      Icon(_showAccounts ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: Colors.white),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_showAccounts) ...[
            for (final slot in slots.slots)
              ListTile(
                leading: CircleAvatar(child: Text(initialsOf(slots.labels[slot] ?? '$slot'))),
                title: Text(slots.labels[slot]?.isNotEmpty == true ? slots.labels[slot]! : '${s.t('account')} $slot'),
                trailing: slot == slots.active ? Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary) : null,
                onTap: () {
                  Navigator.pop(context);
                  ref.read(accountSlotsProvider.notifier).switchTo(slot);
                },
              ),
            if (slots.slots.length < AccountSlotsNotifier.maxAccounts)
              ListTile(
                leading: const Icon(Icons.add_rounded),
                title: Text(s.t('add_account')),
                onTap: () {
                  Navigator.pop(context);
                  ref.read(accountSlotsProvider.notifier).addAccount();
                },
              ),
            const Divider(),
          ],
          ListTile(
            leading: const Icon(Icons.group_add_rounded),
            title: Text(s.t('new_group')),
            onTap: () => _push(const ContactsScreen(createGroup: true)),
          ),
          ListTile(
            leading: const Icon(Icons.campaign_rounded),
            title: Text(s.t('new_channel')),
            onTap: () => _push(const NewChannelScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.person_rounded),
            title: Text(s.t('contacts')),
            onTap: () => _push(const ContactsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_rounded),
            title: Text(s.t('saved_messages')),
            onTap: () async {
              Navigator.pop(context);
              final chat = await guard(context, account.savedMessages);
              if (chat != null && context.mounted) openChat(context, chat.id);
            },
          ),
          ListTile(
            leading: const Icon(Icons.archive_rounded),
            title: Text(s.t('archive')),
            onTap: () => _push(const ArchiveScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.add_a_photo_outlined),
            title: Text(s.t('add_story')),
            onTap: () {
              // The drawer is closing; run the flow on the navigator's (home) context.
              final home = Navigator.of(context).context;
              Navigator.pop(context);
              postStoryFlow(home, ref);
            },
          ),
          ListTile(
            leading: const Icon(Icons.download_rounded),
            title: Text(s.t('downloads')),
            onTap: () => _push(const DownloadsScreen()),
          ),
          if (settings.hiddenChatIds.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: Text(s.t('hidden_chats')),
              onTap: () async {
                // Hidden chats sit behind the passcode when one is set.
                if (ref.read(appLockProvider).enabled) {
                  final pin = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const PinEntryScreen(titleKey: 'passcode_enter')));
                  if (pin == null || !context.mounted) return;
                  if (!await ref.read(appLockProvider.notifier).verify(pin)) {
                    if (context.mounted) showToast(context, s.t('passcode_wrong'));
                    return;
                  }
                }
                _push(const HiddenChatsScreen());
              },
            ),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_off_rounded),
            title: Text(s.t('ghost_mode')),
            subtitle: Text(s.t('ghost_mode_short')),
            value: settings.ghostMode,
            onChanged: (value) {
              ref.read(settingsProvider.notifier).setGhostMode(value);
              account.setOnline(!value);
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_rounded),
            title: Text(s.t('settings')),
            onTap: () => _push(const SettingsScreen()),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
            child: Text(
              s.t('drawer_footer', {'version': AppConfig.appVersion}),
              style: TextStyle(fontSize: 12.5, color: theme.hintColor, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class HiddenChatsScreen extends ConsumerWidget {
  const HiddenChatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        appBar: AppBar(title: Text(context.t('hidden_chats'))),
        body: const ChatListView(listKey: 'hidden'),
      );
}
