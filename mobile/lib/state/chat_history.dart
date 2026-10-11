import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../core/tdlib/td_client.dart';
import 'telegram.dart';

/// Message list of one open chat. Messages are kept newest-first (for a reversed ListView).
class ChatHistory extends ChangeNotifier {
  ChatHistory(this.account, this.chatId, {required this.ghostMode, this.topicId}) {
    _subscription = account.messageEvents.listen(_onEvent);
    unawaited(account.send<td.Ok>(td.OpenChat(chatId: chatId)).catchError((Object _) => const td.Ok()));
  }

  final TelegramAccount account;
  final int chatId;

  /// Forum topic shown by this history; null for the whole chat.
  final int? topicId;
  bool ghostMode;

  final List<td.Message> messages = [];
  bool loading = false;
  bool hasOlder = true;
  bool hasNewer = false;
  bool initialized = false;

  /// First unread message when the chat was opened (draws the "Unread messages" divider).
  int? firstUnreadId;
  String? error;

  /// Official Telegram sponsored messages (channels and bots). Required by the Telegram API Terms;
  /// they are shown to every user and are not affected by ghost mode or any Sado subscription.
  List<td.SponsoredMessage> sponsored = const [];

  /// Minimum number of ordinary messages between sponsored ones; 0 = show one after all messages.
  int sponsoredSpacing = 0;
  final Set<int> _sponsoredViewed = {};

  StreamSubscription<td.Update>? _subscription;
  final Set<int> _viewed = {};
  bool _disposed = false;

  static const _pageSize = 50;

  Future<void> loadInitial() async {
    final chat = account.chats[chatId];
    loading = true;
    try {
      if (topicId == null && chat != null && chat.unreadCount > 0 && chat.lastReadInboxMessageId > 0) {
        // Open at the first unread message, like Telegram.
        final page = await _fetch(chat.lastReadInboxMessageId, -_pageSize ~/ 2, _pageSize);
        _replaceAll(page);
        final unread = page.where((m) => m.id > chat.lastReadInboxMessageId && !m.isOutgoing).map((m) => m.id);
        firstUnreadId = unread.isEmpty ? null : unread.reduce((a, b) => a < b ? a : b);
        hasNewer = chat.lastMessage != null && !page.any((m) => m.id == chat.lastMessage!.id);
      } else {
        _replaceAll(await _fetchLatest());
      }
      hasOlder = messages.isNotEmpty;
      error = null;
    } on TdException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      initialized = true;
      _notify();
    }
    unawaited(loadSponsored());
  }

  Future<void> loadSponsored() async {
    final chat = account.chats[chatId];
    final eligible = chat != null && topicId == null && (account.isChannel(chat) || account.isBot(account.privateUser(chat)));
    if (!eligible) return;
    try {
      final result = await account.send<td.SponsoredMessages>(td.GetChatSponsoredMessages(chatId: chatId));
      sponsored = result.messages;
      sponsoredSpacing = result.messagesBetween;
      _notify();
    } on TdException catch (e) {
      debugPrint('sponsored messages unavailable: ${e.message}');
    }
  }

  /// Reports a sponsored message as viewed once it is fully on screen. Always sent, even in ghost mode:
  /// Telegram requires sponsored views to be reported and ghost mode only hides the user's own activity.
  void markSponsoredViewed(int messageId) {
    if (!_sponsoredViewed.add(messageId)) return;
    unawaited(account
        .send<td.Ok>(td.ViewMessages(chatId: chatId, messageIds: [messageId], source: null, forceRead: false))
        .catchError((Object _) => const td.Ok()));
  }

  Future<void> clickSponsored(td.SponsoredMessage message, {bool isMediaClick = false}) => account.send<td.Ok>(
        td.ClickChatSponsoredMessage(chatId: chatId, messageId: message.messageId, isMediaClick: isMediaClick, fromFullscreen: false),
      );

  /// TDLib may return fewer messages than asked (only what is cached); keep asking until the page is full.
  Future<List<td.Message>> _fetchLatest() async {
    final result = <td.Message>[];
    var from = 0;
    for (var attempt = 0; attempt < 4 && result.length < 30; attempt++) {
      final page = await _fetch(from, 0, _pageSize);
      if (page.isEmpty) break;
      result.addAll(page.where((m) => !result.any((r) => r.id == m.id)));
      from = page.last.id;
    }
    return result;
  }

  Future<List<td.Message>> _fetch(int fromMessageId, int offset, int limit) async {
    final topic = topicId;
    final result = await account.send<td.Messages>(
      topic != null
          ? td.GetForumTopicHistory(chatId: chatId, forumTopicId: topic, fromMessageId: fromMessageId, offset: offset, limit: limit)
          : td.GetChatHistory(chatId: chatId, fromMessageId: fromMessageId, offset: offset, limit: limit, onlyLocal: false),
    );
    final list = (result.messages ?? const <td.Message>[]).toList()..sort((a, b) => b.id.compareTo(a.id));
    return list;
  }

  void _replaceAll(List<td.Message> page) {
    messages
      ..clear()
      ..addAll(page);
  }

  Future<void> loadOlder() async {
    if (loading || !hasOlder || messages.isEmpty) return;
    loading = true;
    try {
      final page = await _fetch(messages.last.id, 0, _pageSize);
      final known = messages.map((m) => m.id).toSet();
      final fresh = page.where((m) => !known.contains(m.id)).toList();
      messages.addAll(fresh);
      hasOlder = fresh.isNotEmpty;
    } on TdException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> loadNewer() async {
    if (loading || !hasNewer || messages.isEmpty) return;
    loading = true;
    try {
      final newest = messages.first.id;
      final page = await _fetch(newest, -(_pageSize - 1), _pageSize);
      final fresh = page.where((m) => m.id > newest).toList();
      messages.insertAll(0, fresh);
      hasNewer = fresh.isNotEmpty;
    } on TdException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      _notify();
    }
  }

  /// Ensures a message is loaded (reply / pinned jumps). Returns false if it no longer exists.
  Future<bool> jumpTo(int messageId) async {
    if (messages.any((m) => m.id == messageId)) return true;
    try {
      final page = await _fetch(messageId, -_pageSize ~/ 2, _pageSize);
      if (!page.any((m) => m.id == messageId)) return false;
      _replaceAll(page);
      hasOlder = true;
      hasNewer = true;
      _notify();
      return true;
    } on TdException {
      return false;
    }
  }

  /// Back to the newest messages (the "scroll down" button while viewing an older window).
  Future<void> jumpToLatest() async {
    if (!hasNewer) return;
    _replaceAll(await _fetchLatest());
    hasNewer = false;
    hasOlder = true;
    _notify();
  }

  int indexOf(int messageId) => messages.indexWhere((m) => m.id == messageId);

  /// Marks messages as read on screen. Skipped entirely in ghost mode.
  void markViewed(Iterable<int> messageIds) {
    if (ghostMode) return;
    final fresh = messageIds.where((id) => id > 0 && _viewed.add(id)).toList();
    if (fresh.isEmpty) return;
    unawaited(account
        .send<td.Ok>(td.ViewMessages(chatId: chatId, messageIds: fresh, source: null, forceRead: true))
        .catchError((Object _) => const td.Ok()));
  }

  void _onEvent(td.Update update) {
    switch (update) {
      case td.UpdateNewMessage(:final message) when message.chatId == chatId:
        if (!_inTopic(message)) return;
        if (hasNewer || messages.any((m) => m.id == message.id)) return;
        messages.insert(0, message);
      case td.UpdateMessageSendSucceeded(:final message, :final oldMessageId) when message.chatId == chatId:
        _replace(oldMessageId, (_) => message);
      case td.UpdateMessageSendFailed(:final message, :final oldMessageId) when message.chatId == chatId:
        _replace(oldMessageId, (_) => message);
      case td.UpdateMessageContent(chatId: final id, :final messageId, :final newContent) when id == chatId:
        _replace(messageId, (m) => m.copyWith(content: newContent));
      case td.UpdateMessageEdited(chatId: final id, :final messageId, :final editDate, :final replyMarkup) when id == chatId:
        _replace(messageId, (m) => _withJson(m, {'edit_date': editDate, 'reply_markup': replyMarkup?.toJson()}));
      case td.UpdateMessageInteractionInfo(chatId: final id, :final messageId, :final interactionInfo) when id == chatId:
        _replace(messageId, (m) => _withJson(m, {'interaction_info': interactionInfo?.toJson()}));
      case td.UpdateMessageIsPinned(chatId: final id, :final messageId, :final isPinned) when id == chatId:
        _replace(messageId, (m) => m.copyWith(isPinned: isPinned));
      case td.UpdateDeleteMessages(chatId: final id, :final messageIds, :final fromCache) when id == chatId:
        if (fromCache) return;
        final ids = messageIds.toSet();
        messages.removeWhere((m) => ids.contains(m.id));
      default:
        return;
    }
    _notify();
  }

  bool _inTopic(td.Message message) {
    final topic = topicId;
    if (topic == null) return true;
    final messageTopic = message.topicId;
    return messageTopic is td.MessageTopicForum && messageTopic.forumTopicId == topic;
  }

  static td.Message _withJson(td.Message message, Map<String, dynamic> changes) =>
      (message.toJson()..addAll(changes)).toTdObject()! as td.Message;

  void _replace(int messageId, td.Message Function(td.Message message) change) {
    final index = indexOf(messageId);
    if (index == -1) return;
    final updated = change(messages[index]);
    messages.removeAt(index);
    // A sent message gets a new (larger) server id; keep the list sorted.
    var insertAt = 0;
    while (insertAt < messages.length && messages[insertAt].id > updated.id) {
      insertAt++;
    }
    messages.insert(insertAt, updated);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    unawaited(account.send<td.Ok>(td.CloseChat(chatId: chatId)).catchError((Object _) => const td.Ok()));
    super.dispose();
  }
}
