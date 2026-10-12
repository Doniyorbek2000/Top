import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../profile/chat_info_screen.dart';
import 'chat_screen.dart';

/// Topic list of a forum supergroup.
class TopicsScreen extends ConsumerStatefulWidget {
  const TopicsScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<TopicsScreen> createState() => _TopicsScreenState();
}

class _TopicsScreenState extends ConsumerState<TopicsScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  final List<td.ForumTopic> _topics = [];
  bool _loading = false;
  bool _hasMore = true;
  String? _error;
  td.ForumTopics? _lastPage;
  Timer? _refreshDebounce;
  late final ValueNotifier<int> _chatRevision = _account.chatRevision(widget.chatId);

  @override
  void initState() {
    super.initState();
    _chatRevision.addListener(_scheduleRefresh);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _chatRevision.removeListener(_scheduleRefresh);
    _refreshDebounce?.cancel();
    super.dispose();
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 800), () => unawaited(_reload()));
  }

  Future<void> _reload() async {
    try {
      final page = await _account.forumTopics(widget.chatId);
      if (!mounted) return;
      setState(() {
        _topics
          ..clear()
          ..addAll(page.topics);
        _lastPage = page;
        _hasMore = page.topics.isNotEmpty && _topics.length < page.totalCount;
        _error = null;
      });
    } on TdException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _loadMore() async {
    final last = _lastPage;
    if (_loading || !_hasMore || last == null) return;
    _loading = true;
    try {
      final page = await _account.forumTopics(
        widget.chatId,
        offsetDate: last.nextOffsetDate,
        offsetMessageId: last.nextOffsetMessageId,
        offsetTopicId: last.nextOffsetForumTopicId,
      );
      if (!mounted) return;
      setState(() {
        final known = _topics.map((t) => t.info.forumTopicId).toSet();
        _topics.addAll(page.topics.where((t) => !known.contains(t.info.forumTopicId)));
        _lastPage = page;
        _hasMore = page.topics.isNotEmpty;
      });
    } on TdException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      _loading = false;
    }
  }

  void _open(td.ForumTopic topic) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChatScreen(chatId: widget.chatId, topicId: topic.info.forumTopicId, topicName: topic.info.name),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider(widget.chatId));
    final s = context.s;
    final visible = _topics.where((t) => !t.info.isHidden || t.info.isGeneral).toList();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatInfoScreen(chatId: widget.chatId))),
          child: Row(
            children: [
              ChatAvatar(chatId: widget.chatId, size: 40, showOnline: false),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(chat?.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
                    Text(s.count('topics', _lastPage?.totalCount ?? _topics.length),
                        style: const TextStyle(fontSize: 13, color: Colors.white70, fontWeight: FontWeight.w400)),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: s.t('view_as_messages'),
            icon: const Icon(Icons.chat_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(chatId: widget.chatId))),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: _error != null && _topics.isEmpty
            ? ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))])
            : _topics.isEmpty && _lastPage == null
                ? const Center(child: CircularProgressIndicator())
                : NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.extentAfter < 400) unawaited(_loadMore());
                      return false;
                    },
                    child: ListView.separated(
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                      itemBuilder: (context, index) => _TopicTile(topic: visible[index], onTap: () => _open(visible[index])),
                    ),
                  ),
      ),
    );
  }
}

class _TopicTile extends ConsumerWidget {
  const _TopicTile({required this.topic, required this.onTap});

  final td.ForumTopic topic;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final info = topic.info;
    final color = Color(0xFF000000 | (info.icon.color == 0 ? 0x6FB9F0 : info.icon.color));
    final last = topic.lastMessage;
    final sender = last == null ? '' : account.senderName(last.senderId);
    final muted = topic.notificationSettings.muteFor > 0;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: color.withValues(alpha: 0.18),
        child: Icon(info.isGeneral ? Icons.tag_rounded : Icons.chat_bubble_rounded, color: color),
      ),
      title: Row(
        children: [
          Expanded(child: Text(info.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (info.isClosed) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.lock_rounded, size: 15, color: Theme.of(context).hintColor)),
          if (last != null)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(formatChatTime(last.date, s.locale), style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
            ),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              last == null ? '' : '${sender.isEmpty ? '' : '$sender: '}${messagePreview(last, account, s)}'.replaceAll('\n', ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (topic.isPinned) Icon(Icons.push_pin_rounded, size: 15, color: Theme.of(context).hintColor),
          if (topic.unreadMentionCount > 0)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: CircleAvatar(radius: 10, backgroundColor: Theme.of(context).colorScheme.primary, child: const Text('@', style: TextStyle(fontSize: 12, color: Colors.white))),
            ),
          if (topic.unreadCount > 0)
            Container(
              margin: const EdgeInsets.only(left: 4),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: muted ? Theme.of(context).hintColor : Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(formatCount(topic.unreadCount), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}
