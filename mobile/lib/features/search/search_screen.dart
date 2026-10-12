import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';

class _SearchResults {
  const _SearchResults({this.chats = const [], this.global = const [], this.messages = const []});

  final List<int> chats;
  final List<int> global;
  final List<td.Message> messages;
}

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  Timer? _debounce;
  String _query = '';
  bool _loading = false;
  _SearchResults _results = const _SearchResults();
  int _generation = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _query = value.trim();
    if (_query.isEmpty) {
      setState(() => _results = const _SearchResults());
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search() async {
    final query = _query;
    final generation = ++_generation;
    final account = ref.read(accountProvider);
    setState(() => _loading = true);
    Future<List<int>> safeChats(Future<td.Chats> request) async {
      try {
        return (await request).chatIds;
      } on TdException {
        return const [];
      }
    }

    final local = safeChats(account.send<td.Chats>(td.SearchChats(query: query, typeFilter: null, limit: 30)));
    final server = safeChats(account.send<td.Chats>(td.SearchChatsOnServer(query: query, typeFilter: null, limit: 30)));
    final public = query.length >= 4
        ? safeChats(account.send<td.Chats>(td.SearchPublicChats(query: query, typeFilter: null)))
        : Future.value(const <int>[]);
    Future<List<td.Message>> messages() async {
      if (query.length < 2) return const [];
      try {
        final found = await account.send<td.FoundMessages>(td.SearchMessages(
          chatList: const td.ChatListMain(),
          query: query,
          offset: '',
          limit: 50,
          filter: null,
          chatTypeFilter: null,
          minDate: 0,
          maxDate: 0,
        ));
        return found.messages;
      } on TdException {
        return const [];
      }
    }

    final results = await Future.wait([local, server, public]);
    final foundMessages = await messages();
    if (!mounted || generation != _generation) return;
    final mine = {...results[0], ...results[1]}.toList();
    setState(() {
      _loading = false;
      _results = _SearchResults(
        chats: mine,
        global: results[2].where((id) => !mine.contains(id)).toList(),
        messages: foundMessages,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    ref.watch(chatListProvider('main'));
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          cursorColor: Colors.white,
          decoration: InputDecoration(hintText: s.t('search'), hintStyle: const TextStyle(color: Colors.white70), border: InputBorder.none),
          onChanged: _onChanged,
        ),
        bottom: _loading ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2)) : null,
      ),
      body: _query.isEmpty
          ? _RecentChats(onTap: (id) => openChat(context, id))
          : ListView(
              children: [
                if (_results.chats.isNotEmpty) SectionHeader(s.t('chats_and_contacts')),
                for (final id in _results.chats) _chatTile(context, id),
                if (_results.global.isNotEmpty) SectionHeader(s.t('global_search')),
                for (final id in _results.global) _chatTile(context, id, showUsername: true),
                if (_results.messages.isNotEmpty) SectionHeader(s.t('messages')),
                for (final message in _results.messages)
                  ListTile(
                    leading: ChatAvatar(chatId: message.chatId, size: 46),
                    title: Text(
                      account.chats[message.chatId] == null ? '' : chatTitle(account.chats[message.chatId]!, account, s),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(messagePreview(message, account, s), maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Text(formatChatTime(message.date, s.locale), style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
                    onTap: () => openChat(context, message.chatId, messageId: message.id),
                  ),
                if (!_loading && _results.chats.isEmpty && _results.global.isEmpty && _results.messages.isEmpty)
                  Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(s.t('nothing_found')))),
              ],
            ),
    );
  }

  Widget _chatTile(BuildContext context, int chatId, {bool showUsername = false}) {
    final account = ref.read(accountProvider);
    final chat = account.chats[chatId];
    if (chat == null) return const SizedBox.shrink();
    final s = context.s;
    final username = account.usernameOf(chat);
    return ListTile(
      leading: ChatAvatar(chatId: chatId, size: 46),
      title: Text(chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        showUsername && username != null ? '@$username, ${chatSubtitle(chat, account, s)}' : chatSubtitle(chat, account, s),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => openChat(context, chatId),
    );
  }
}

/// Top chats shown before typing (Telegram shows recent/frequent chats).
class _RecentChats extends ConsumerWidget {
  const _RecentChats({required this.onTap});

  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatListProvider('main')).take(20).toList();
    final account = ref.watch(accountProvider);
    final s = context.s;
    return ListView(
      children: [
        SectionHeader(s.t('recent')),
        SizedBox(
          height: 96,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final chat in chats)
                InkWell(
                  onTap: () => onTap(chat.id),
                  child: SizedBox(
                    width: 76,
                    child: Column(
                      children: [
                        const SizedBox(height: 6),
                        ChatAvatar(chatId: chat.id, size: 54),
                        const SizedBox(height: 4),
                        Text(chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
