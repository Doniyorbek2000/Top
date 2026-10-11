import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../core/config.dart';
import '../core/tdlib/td_client.dart';

/// Stable key for a chat list (main, archive or a folder).
String chatListKey(td.ChatList list) => switch (list) {
      td.ChatListMain() => 'main',
      td.ChatListArchive() => 'archive',
      td.ChatListFolder(:final chatFolderId) => 'folder:$chatFolderId',
      _ => list.getConstructor(),
    };

td.ChatList chatListFromKey(String key) {
  if (key == 'archive') return const td.ChatListArchive();
  if (key.startsWith('folder:')) return td.ChatListFolder(chatFolderId: int.parse(key.substring(7)));
  return const td.ChatListMain();
}

/// A chat action (typing, recording...) currently shown for a chat.
class ActiveChatAction {
  const ActiveChatAction(this.senderId, this.action);

  final int senderId;
  final td.ChatAction action;
}

/// One Telegram account: the TDLib client plus an in-memory mirror of the objects TDLib pushes.
///
/// TDLib guarantees that every object referenced by an update has been sent before (updateNewChat,
/// updateUser, updateFile...), so these maps are the single source of truth for the UI.
class TelegramAccount {
  TelegramAccount._(this.slot, this.client, this.databaseDirectory);

  final int slot;
  final TdClient client;
  final String databaseDirectory;

  final Map<int, td.Chat> chats = {};
  final Map<int, td.User> users = {};
  final Map<int, td.BasicGroup> basicGroups = {};
  final Map<int, td.Supergroup> supergroups = {};
  final Map<int, td.File> files = {};
  final Map<String, td.OptionValue> options = {};
  final Map<int, Map<int, ActiveChatAction>> chatActions = {};
  final Map<int, int> onlineMemberCounts = {};
  final Map<String, bool> _listFullyLoaded = {};
  List<td.ChatFolderInfo> folders = const [];
  final Map<String, int> unreadCounts = {};

  /// Active stories per poster chat (updateChatActiveStories).
  final Map<int, td.ChatActiveStories> activeStories = {};
  final storiesRevision = ValueNotifier<int>(0);

  /// Chats with active stories in the main story list, newest first.
  List<td.ChatActiveStories> storyFeed() {
    final feed = activeStories.values.where((s) => s.stories.isNotEmpty && s.list is td.StoryListMain && s.order != 0).toList()
      ..sort((a, b) => b.order.compareTo(a.order));
    return feed;
  }

  final Map<int, td.SecretChat> secretChats = {};

  td.SecretChat? secretChatOf(td.Chat chat) =>
      chat.type is td.ChatTypeSecret ? secretChats[(chat.type as td.ChatTypeSecret).secretChatId] : null;

  /// Forum topic currently open per chat; messages sent to that chat go into the topic.
  final Map<int, int> activeTopics = {};

  td.MessageTopic? topicFor(int chatId) {
    final topic = activeTopics[chatId];
    return topic == null ? null : td.MessageTopicForum(forumTopicId: topic);
  }

  bool isForum(td.Chat chat) => supergroupOf(chat)?.isForum ?? false;

  /// Message carrying the current bot reply keyboard of a chat (updateChatReplyMarkup).
  final Map<int, td.Message> replyMarkupMessages = {};

  /// Writing styles offered by Telegram's AI text composer (updateTextCompositionStyles).
  List<td.TextCompositionStyle> compositionStyles = const [];

  final authState = ValueNotifier<td.AuthorizationState?>(null);
  final connectionState = ValueNotifier<td.ConnectionState>(const td.ConnectionStateConnecting());

  /// Bumped (coalesced per microtask) whenever anything shown in chat lists changes.
  final chatListRevision = ValueNotifier<int>(0);
  final usersRevision = ValueNotifier<int>(0);
  final foldersRevision = ValueNotifier<int>(0);
  final Map<int, ValueNotifier<int>> _chatRevisions = {};

  final _fileUpdates = StreamController<td.File>.broadcast(sync: true);
  final _messageEvents = StreamController<td.Update>.broadcast(sync: true);
  StreamSubscription<td.TdObject>? _subscription;
  final Map<int, Timer> _actionTimers = {};
  bool _listDirty = false;
  bool _usersDirty = false;
  final Set<int> _dirtyChats = {};
  TelegramCredentials? _credentials;
  String _languageCode = 'en';

  static bool _logConfigured = false;

  static Future<TelegramAccount> start(int slot, TelegramCredentials credentials, {String languageCode = 'en'}) async {
    if (!_logConfigured) {
      _logConfigured = true;
      TdClient.executeStatic(const td.SetLogVerbosityLevel(newVerbosityLevel: kDebugMode ? 2 : 1));
    }
    final support = await getApplicationSupportDirectory();
    final dir = '${support.path}${Platform.pathSeparator}tdlib${Platform.pathSeparator}account_$slot';
    await Directory(dir).create(recursive: true);
    final client = await TdClient.create();
    final account = TelegramAccount._(slot, client, dir)
      .._credentials = credentials
      .._languageCode = languageCode;
    account._subscription = client.updates.listen(account._onUpdate);
    return account;
  }

  /// Desktop/test entry point with an explicit database directory.
  @visibleForTesting
  static Future<TelegramAccount> startAt(String dir, TelegramCredentials credentials) async {
    await Directory(dir).create(recursive: true);
    final client = await TdClient.create();
    final account = TelegramAccount._(0, client, dir).._credentials = credentials;
    account._subscription = client.updates.listen(account._onUpdate);
    return account;
  }

  // ------------------------------------------------------------------ getters

  int get myId => switch (options['my_id']) { td.OptionValueInteger(:final value) => value, _ => 0 };

  bool get isReady => authState.value is td.AuthorizationStateReady;

  td.User? get me => users[myId];

  Stream<td.File> fileUpdates(int fileId) => _fileUpdates.stream.where((f) => f.id == fileId);

  /// Message-level updates (new/edited/deleted messages, send results...) for chat history controllers.
  Stream<td.Update> get messageEvents => _messageEvents.stream;

  ValueNotifier<int> chatRevision(int chatId) => _chatRevisions.putIfAbsent(chatId, () => ValueNotifier(0));

  td.ChatPosition? positionIn(td.Chat chat, td.ChatList list) {
    final key = chatListKey(list);
    for (final position in chat.positions) {
      if (chatListKey(position.list) == key) return position;
    }
    return null;
  }

  /// Chats of a list in display order (pinned first, then by TDLib's order).
  List<td.Chat> chatList(td.ChatList list) {
    final result = <(td.Chat, td.ChatPosition)>[];
    for (final chat in chats.values) {
      final position = positionIn(chat, list);
      if (position != null && position.order != 0) result.add((chat, position));
    }
    result.sort((a, b) {
      if (a.$2.isPinned != b.$2.isPinned) return a.$2.isPinned ? -1 : 1;
      return b.$2.order.compareTo(a.$2.order);
    });
    return [for (final entry in result) entry.$1];
  }

  bool isListFullyLoaded(td.ChatList list) => _listFullyLoaded[chatListKey(list)] ?? false;

  bool isSavedMessages(td.Chat chat) => chat.type is td.ChatTypePrivate && (chat.type as td.ChatTypePrivate).userId == myId;

  td.User? privateUser(td.Chat chat) => switch (chat.type) {
        td.ChatTypePrivate(:final userId) => users[userId],
        td.ChatTypeSecret(:final userId) => users[userId],
        _ => null,
      };

  td.Supergroup? supergroupOf(td.Chat chat) =>
      chat.type is td.ChatTypeSupergroup ? supergroups[(chat.type as td.ChatTypeSupergroup).supergroupId] : null;

  td.BasicGroup? basicGroupOf(td.Chat chat) =>
      chat.type is td.ChatTypeBasicGroup ? basicGroups[(chat.type as td.ChatTypeBasicGroup).basicGroupId] : null;

  bool isChannel(td.Chat chat) => chat.type is td.ChatTypeSupergroup && (chat.type as td.ChatTypeSupergroup).isChannel;

  bool isGroup(td.Chat chat) =>
      chat.type is td.ChatTypeBasicGroup || (chat.type is td.ChatTypeSupergroup && !isChannel(chat));

  bool isBot(td.User? user) => user?.type is td.UserTypeBot;

  bool isMuted(td.Chat chat) => chat.notificationSettings.muteFor > 0;

  td.ChatMemberStatus? myStatus(td.Chat chat) => supergroupOf(chat)?.status ?? basicGroupOf(chat)?.status;

  bool isAdmin(td.Chat chat) {
    final status = myStatus(chat);
    return status is td.ChatMemberStatusCreator || status is td.ChatMemberStatusAdministrator;
  }

  bool isMember(td.Chat chat) {
    final status = myStatus(chat);
    if (status == null) return true;
    return switch (status) {
      td.ChatMemberStatusLeft() || td.ChatMemberStatusBanned() => false,
      td.ChatMemberStatusRestricted(:final isMember) => isMember,
      td.ChatMemberStatusCreator(:final isMember) => isMember,
      _ => true,
    };
  }

  bool canSendMessages(td.Chat chat) {
    if (!isMember(chat)) return false;
    if (chat.type is td.ChatTypeSecret) return secretChatOf(chat)?.state is td.SecretChatStateReady;
    final user = privateUser(chat);
    if (user != null) return user.type is! td.UserTypeDeleted;
    if (isChannel(chat)) {
      final status = myStatus(chat);
      return status is td.ChatMemberStatusCreator ||
          (status is td.ChatMemberStatusAdministrator && status.rights.canPostMessages);
    }
    final status = myStatus(chat);
    if (status is td.ChatMemberStatusCreator || status is td.ChatMemberStatusAdministrator) return true;
    if (status is td.ChatMemberStatusRestricted) return status.permissions.canSendBasicMessages;
    return chat.permissions.canSendBasicMessages;
  }

  int memberCount(td.Chat chat) => supergroupOf(chat)?.memberCount ?? basicGroupOf(chat)?.memberCount ?? 0;

  String? usernameOf(td.Chat chat) {
    final user = privateUser(chat);
    final usernames = user?.usernames ?? supergroupOf(chat)?.usernames;
    if (usernames == null || usernames.activeUsernames.isEmpty) return null;
    return usernames.activeUsernames.first;
  }

  String userName(int userId) {
    final user = users[userId];
    if (user == null) return '';
    if (user.type is td.UserTypeDeleted) return 'Deleted Account';
    return '${user.firstName} ${user.lastName}'.trim();
  }

  String senderName(td.MessageSender sender) => switch (sender) {
        td.MessageSenderUser(:final userId) => userName(userId),
        td.MessageSenderChat(:final chatId) => chats[chatId]?.title ?? '',
        _ => '',
      };

  int senderKey(td.MessageSender sender) => switch (sender) {
        td.MessageSenderUser(:final userId) => userId,
        td.MessageSenderChat(:final chatId) => chatId,
        _ => 0,
      };

  // ------------------------------------------------------------------ update handling

  void _markList() {
    if (_listDirty) return;
    _listDirty = true;
    scheduleMicrotask(() {
      _listDirty = false;
      chatListRevision.value++;
    });
  }

  void _markUsers() {
    if (_usersDirty) return;
    _usersDirty = true;
    scheduleMicrotask(() {
      _usersDirty = false;
      usersRevision.value++;
    });
  }

  void _markChat(int chatId, {bool affectsList = true}) {
    if (affectsList) _markList();
    if (_dirtyChats.add(chatId) && _dirtyChats.length == 1) {
      scheduleMicrotask(() {
        final dirty = _dirtyChats.toList();
        _dirtyChats.clear();
        for (final id in dirty) {
          final notifier = _chatRevisions[id];
          if (notifier != null) notifier.value++;
        }
      });
    }
  }

  /// Rebuilds an immutable TDLib object with some JSON fields replaced (supports setting fields to null).
  static T _patch<T extends td.TdObject>(T object, Map<String, dynamic> changes) {
    final json = object.toJson()..addAll(changes);
    return json.toTdObject()! as T;
  }

  void _updateChat(int chatId, td.Chat Function(td.Chat chat) change, {bool affectsList = true}) {
    final chat = chats[chatId];
    if (chat == null) return;
    chats[chatId] = change(chat);
    _markChat(chatId, affectsList: affectsList);
  }

  void _setPosition(int chatId, td.ChatPosition position) {
    _updateChat(chatId, (chat) {
      final key = chatListKey(position.list);
      final positions = chat.positions.where((p) => chatListKey(p.list) != key).toList();
      if (position.order != 0) positions.add(position);
      return chat.copyWith(positions: positions);
    });
  }

  void _setPositions(int chatId, List<td.ChatPosition> positions) {
    for (final position in positions) {
      _setPosition(chatId, position);
    }
  }

  /// Feeds an update as if it came from TDLib (tests only).
  @visibleForTesting
  void debugHandleUpdate(td.TdObject object) => _onUpdate(object);

  void _onUpdate(td.TdObject object) {
    switch (object) {
      case td.UpdateAuthorizationState(:final authorizationState):
        _onAuthorizationState(authorizationState);
      case td.UpdateOption(:final name, :final value):
        options[name] = value;
        if (name == 'my_id') _markUsers();
      case td.UpdateConnectionState(:final state):
        connectionState.value = state;
      case td.UpdateNewChat(:final chat):
        chats[chat.id] = chat;
        _markChat(chat.id);
      case td.UpdateChatTitle(:final chatId, :final title):
        _updateChat(chatId, (c) => c.copyWith(title: title));
      case td.UpdateChatPhoto(:final chatId, :final photo):
        _updateChat(chatId, (c) => _patch(c, {'photo': photo?.toJson()}));
      case td.UpdateChatPermissions(:final chatId, :final permissions):
        _updateChat(chatId, (c) => c.copyWith(permissions: permissions), affectsList: false);
      case td.UpdateChatLastMessage(:final chatId, :final lastMessage, :final positions):
        _updateChat(chatId, (c) => _patch(c, {'last_message': lastMessage?.toJson()}));
        _setPositions(chatId, positions);
      case td.UpdateChatPosition(:final chatId, :final position):
        _setPosition(chatId, position);
      case td.UpdateChatAddedToList(:final chatId, :final chatList):
        _updateChat(chatId, (c) => c.copyWith(chatLists: [...c.chatLists, chatList]));
      case td.UpdateChatRemovedFromList(:final chatId, :final chatList):
        final key = chatListKey(chatList);
        _updateChat(chatId, (c) => c.copyWith(chatLists: c.chatLists.where((l) => chatListKey(l) != key).toList()));
      case td.UpdateChatReadInbox(:final chatId, :final lastReadInboxMessageId, :final unreadCount):
        _updateChat(chatId, (c) => c.copyWith(lastReadInboxMessageId: lastReadInboxMessageId, unreadCount: unreadCount));
      case td.UpdateChatReadOutbox(:final chatId, :final lastReadOutboxMessageId):
        _updateChat(chatId, (c) => c.copyWith(lastReadOutboxMessageId: lastReadOutboxMessageId));
      case td.UpdateChatUnreadMentionCount(:final chatId, :final unreadMentionCount):
        _updateChat(chatId, (c) => c.copyWith(unreadMentionCount: unreadMentionCount));
      case td.UpdateChatUnreadReactionCount(:final chatId, :final unreadReactionCount):
        _updateChat(chatId, (c) => c.copyWith(unreadReactionCount: unreadReactionCount));
      case td.UpdateChatNotificationSettings(:final chatId, :final notificationSettings):
        _updateChat(chatId, (c) => c.copyWith(notificationSettings: notificationSettings));
      case td.UpdateChatDraftMessage(:final chatId, :final draftMessage, :final positions):
        _updateChat(chatId, (c) => _patch(c, {'draft_message': draftMessage?.toJson()}));
        _setPositions(chatId, positions);
      case td.UpdateChatHasScheduledMessages(:final chatId, :final hasScheduledMessages):
        _updateChat(chatId, (c) => c.copyWith(hasScheduledMessages: hasScheduledMessages), affectsList: false);
      case td.UpdateChatIsMarkedAsUnread(:final chatId, :final isMarkedAsUnread):
        _updateChat(chatId, (c) => c.copyWith(isMarkedAsUnread: isMarkedAsUnread));
      case td.UpdateChatOnlineMemberCount(:final chatId, :final onlineMemberCount):
        onlineMemberCounts[chatId] = onlineMemberCount;
        _markChat(chatId, affectsList: false);
      case td.UpdateChatActiveStories(:final activeStories):
        this.activeStories[activeStories.chatId] = activeStories;
        storiesRevision.value++;
      case td.UpdateChatReplyMarkup(:final chatId, :final replyMarkupMessage):
        if (replyMarkupMessage == null) {
          replyMarkupMessages.remove(chatId);
        } else {
          replyMarkupMessages[chatId] = replyMarkupMessage;
        }
        _updateChat(chatId, (c) => c.copyWith(replyMarkupMessageId: replyMarkupMessage?.id ?? 0), affectsList: false);
      case td.UpdateChatAction(:final chatId, :final senderId, :final action):
        _onChatAction(chatId, senderKey(senderId), action);
      case td.UpdateUser(:final user):
        users[user.id] = user;
        _markUsers();
        _markList();
      case td.UpdateUserStatus(:final userId, :final status):
        final user = users[userId];
        if (user != null) {
          users[userId] = user.copyWith(status: status);
          _markUsers();
          _markList();
        }
      case td.UpdateSecretChat(:final secretChat):
        secretChats[secretChat.id] = secretChat;
        _markList();
        for (final chat in chats.values) {
          if (chat.type case td.ChatTypeSecret(:final secretChatId) when secretChatId == secretChat.id) _markChat(chat.id);
        }
      case td.UpdateBasicGroup(:final basicGroup):
        basicGroups[basicGroup.id] = basicGroup;
        _markList();
      case td.UpdateSupergroup(:final supergroup):
        supergroups[supergroup.id] = supergroup;
        _markList();
      case td.UpdateFile(:final file):
        files[file.id] = file;
        _fileUpdates.add(file);
      case td.UpdateChatFolders(:final chatFolders):
        folders = chatFolders;
        foldersRevision.value++;
      case td.UpdateUnreadMessageCount(:final chatList, :final unreadCount):
        unreadCounts[chatListKey(chatList)] = unreadCount;
        foldersRevision.value++;
      case td.UpdateTextCompositionStyles(:final styles):
        compositionStyles = styles;
      case td.UpdateNewMessage(:final message):
        _clearAction(message.chatId, senderKey(message.senderId));
        _messageEvents.add(object);
      case td.UpdateMessageSendSucceeded() ||
            td.UpdateMessageSendFailed() ||
            td.UpdateMessageContent() ||
            td.UpdateMessageEdited() ||
            td.UpdateDeleteMessages() ||
            td.UpdateMessageInteractionInfo() ||
            td.UpdateMessageIsPinned() ||
            td.UpdateMessageSendAcknowledged():
        _messageEvents.add(object as td.Update);
      default:
        break;
    }
  }

  void _onChatAction(int chatId, int senderId, td.ChatAction action) {
    final timerKey = chatId ^ (senderId << 20);
    _actionTimers.remove(timerKey)?.cancel();
    if (action is td.ChatActionCancel) {
      _clearAction(chatId, senderId);
      return;
    }
    chatActions.putIfAbsent(chatId, () => {})[senderId] = ActiveChatAction(senderId, action);
    _markChat(chatId);
    // TDLib re-sends active actions every few seconds; expire stale ones defensively.
    _actionTimers[timerKey] = Timer(const Duration(seconds: 6), () => _clearAction(chatId, senderId));
  }

  void _clearAction(int chatId, int senderId) {
    final actions = chatActions[chatId];
    if (actions == null || actions.remove(senderId) == null) return;
    if (actions.isEmpty) chatActions.remove(chatId);
    _markChat(chatId);
  }

  Future<void> _onAuthorizationState(td.AuthorizationState state) async {
    authState.value = state;
    if (state is td.AuthorizationStateWaitTdlibParameters) {
      final credentials = _credentials!;
      try {
        await client.send<td.Ok>(td.SetTdlibParameters(
          useTestDc: AppConfig.useTestDc,
          databaseDirectory: databaseDirectory,
          filesDirectory: '$databaseDirectory${Platform.pathSeparator}files',
          databaseEncryptionKey: await _databaseKey(),
          useFileDatabase: true,
          useChatInfoDatabase: true,
          useMessageDatabase: true,
          useSecretChats: true,
          apiId: credentials.apiId,
          apiHash: credentials.apiHash,
          systemLanguageCode: _languageCode,
          deviceModel: _deviceModel(),
          systemVersion: Platform.operatingSystemVersion,
          applicationVersion: AppConfig.appVersion,
        ));
      } on TdException catch (error) {
        debugPrint('setTdlibParameters failed: $error');
      }
    } else if (state is td.AuthorizationStateReady) {
      unawaited(_afterLogin());
    }
  }

  Future<String> _databaseKey() async {
    // The database is encrypted with a random per-account key kept next to it in app-private storage.
    final file = File('$databaseDirectory${Platform.pathSeparator}.key');
    if (await file.exists()) return (await file.readAsString()).trim();
    final random = Random.secure();
    final key = base64Encode(List<int>.generate(32, (_) => random.nextInt(256)));
    await file.writeAsString(key, flush: true);
    return key;
  }

  static String _deviceModel() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iPhone';
    return Platform.operatingSystem;
  }

  Future<void> _afterLogin() async {
    try {
      await loadChats(const td.ChatListMain(), limit: 50);
    } on TdException catch (error) {
      debugPrint('initial loadChats failed: $error');
    }
    await loadStories();
  }

  bool _storiesFullyLoaded = false;

  /// Loads the main story list; TDLib answers 404 once every chat with stories was sent.
  Future<void> loadStories() async {
    if (_storiesFullyLoaded) return;
    try {
      await client.send<td.Ok>(const td.LoadActiveStories(storyList: td.StoryListMain()));
    } on TdException catch (error) {
      if (error.code == 404) {
        _storiesFullyLoaded = true;
      } else {
        debugPrint('loadActiveStories failed: $error');
      }
    }
  }

  // ------------------------------------------------------------------ requests

  Future<T> send<T extends td.TdObject>(td.TdFunction function) => client.send<T>(function);

  /// Asks TDLib to load more chats of a list; returns false when everything is already loaded.
  Future<bool> loadChats(td.ChatList list, {int limit = 100}) async {
    final key = chatListKey(list);
    if (_listFullyLoaded[key] ?? false) return false;
    try {
      await client.send<td.Ok>(td.LoadChats(chatList: list, limit: limit));
      return true;
    } on TdException catch (error) {
      if (error.code == 404) {
        _listFullyLoaded[key] = true;
        _markList();
        return false;
      }
      rethrow;
    }
  }

  /// Starts (or joins) a download and completes with the local path once finished.
  Future<String?> downloadFile(int fileId, {int priority = 16}) async {
    final cached = files[fileId];
    if (cached != null && cached.local.isDownloadingCompleted) return cached.local.path;
    try {
      final file = await client.send<td.File>(
        td.DownloadFile(fileId: fileId, priority: priority, offset: 0, limit: 0, synchronous: true),
      );
      files[file.id] = file;
      return file.local.isDownloadingCompleted ? file.local.path : null;
    } on TdException catch (error) {
      debugPrint('download $fileId failed: $error');
      return null;
    }
  }

  void cancelDownload(int fileId) {
    unawaited(client.send<td.Ok>(td.CancelDownloadFile(fileId: fileId, onlyIfPending: false)).catchError((Object _) => const td.Ok()));
  }

  Future<td.Chat> getChat(int chatId) async {
    final chat = chats[chatId];
    if (chat != null) return chat;
    return client.send<td.Chat>(td.GetChat(chatId: chatId));
  }

  Future<td.User?> getUser(int userId) async {
    final user = users[userId];
    if (user != null) return user;
    try {
      return await client.send<td.User>(td.GetUser(userId: userId));
    } on TdException {
      return null;
    }
  }

  /// Ghost mode: stop broadcasting online status.
  Future<void> setOnline(bool online) async {
    try {
      await client.send<td.Ok>(td.SetOption(name: 'online', value: td.OptionValueBoolean(value: online)));
    } on TdException catch (error) {
      debugPrint('set online failed: $error');
    }
  }

  Future<void> logOut() => client.send<td.Ok>(const td.LogOut());

  Future<void> dispose() async {
    try {
      if (!client.isClosed) await client.send<td.Ok>(const td.Close()).timeout(const Duration(seconds: 5));
    } on Object catch (error) {
      debugPrint('close failed: $error');
    }
    await _subscription?.cancel();
    for (final timer in _actionTimers.values) {
      timer.cancel();
    }
    await _fileUpdates.close();
    await _messageEvents.close();
  }
}
