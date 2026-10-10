// Runs against a real libtdjson build. Set TDJSON_PATH to the library, e.g.
//   TDJSON_PATH=/path/to/libtdjson.so flutter test test/tdlib_integration_test.dart
@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/config.dart';
import 'package:sado/core/tdlib/td_client.dart';
import 'package:sado/state/telegram.dart';
import 'package:tdlib_ex/td_api.dart' as td;

final _libraryPath = Platform.environment['TDJSON_PATH'];

td.Chat _chat(int id, String title) => td.Chat.fromJson({
      '@type': 'chat',
      'id': id,
      'type': {'@type': 'chatTypeBasicGroup', 'basic_group_id': id},
      'title': title,
      'permissions': {'@type': 'chatPermissions', 'can_send_basic_messages': true},
      'positions': <Object>[],
      'chat_lists': <Object>[],
      'notification_settings': {'@type': 'chatNotificationSettings', 'mute_for': 0},
      'available_reactions': {'@type': 'chatAvailableReactionsAll', 'max_reaction_count': 11},
      'video_chat': {'@type': 'videoChat', 'group_call_id': 0, 'has_participants': false},
      'unread_count': 0,
      'client_data': '',
    })!;

void main() {
  final skip = (_libraryPath ?? '').isEmpty ? 'TDJSON_PATH is not set' : null;

  group('TDLib FFI transport', () {
    test('synchronous execute parses entities', () {
      final result = TdClient.executeStatic(const td.GetTextEntities(text: 'see https://t.me/durov and @sado'));
      expect(result, isNotNull);
      final entities = td.TextEntities.fromJson(result)!;
      expect(entities.entities.map((e) => e.type.runtimeType), containsAll([td.TextEntityTypeUrl, td.TextEntityTypeMention]));
    }, skip: skip);

    test('async request round-trips through the receive isolate', () async {
      final client = await TdClient.create();
      final echoed = await client.send<td.TestString>(const td.TestCallString(x: 'Sado ✓ салом'));
      expect(echoed.value, 'Sado ✓ салом');
      // Several concurrent requests are matched to the right callers by @extra.
      final results = await Future.wait([
        for (var i = 0; i < 20; i++) client.send<td.TestString>(td.TestCallString(x: 'n$i')),
      ]);
      expect(results.map((r) => r.value), [for (var i = 0; i < 20; i++) 'n$i']);
    }, skip: skip);

    test('TDLib errors surface as TdException', () async {
      final client = await TdClient.create();
      await expectLater(
        client.send<td.Chat>(const td.GetChat(chatId: 123456789)),
        throwsA(isA<TdException>()),
      );
    }, skip: skip);
  });

  group('TelegramAccount', () {
    late Directory dir;
    late TelegramAccount account;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sado_tdlib_');
      // Credentials are only validated by Telegram's servers; locally TDLib accepts any well-formed pair.
      account = await TelegramAccount.startAt(dir.path, const TelegramCredentials(12345, '0123456789abcdef0123456789abcdef'));
    });

    tearDown(() async {
      await account.dispose();
      await dir.delete(recursive: true);
    });

    test('initializes the database and asks for a phone number', () async {
      final completer = Completer<td.AuthorizationState>();
      void listener() {
        final state = account.authState.value;
        if (state is td.AuthorizationStateWaitPhoneNumber && !completer.isCompleted) completer.complete(state);
      }

      account.authState.addListener(listener);
      listener();
      final state = await completer.future.timeout(const Duration(seconds: 30));
      expect(state, isA<td.AuthorizationStateWaitPhoneNumber>());
      expect(File('${dir.path}/.key').existsSync(), isTrue, reason: 'database encryption key is created');
      expect(account.options['version'], isA<td.OptionValueString>());
    }, skip: skip);

    test('mirrors chat updates and orders chat lists like Telegram', () async {
      account
        ..debugHandleUpdate(td.UpdateNewChat(chat: _chat(1, 'Old')))
        ..debugHandleUpdate(td.UpdateNewChat(chat: _chat(2, 'New')))
        ..debugHandleUpdate(td.UpdateNewChat(chat: _chat(3, 'Pinned')))
        ..debugHandleUpdate(const td.UpdateChatPosition(
            chatId: 1, position: td.ChatPosition(list: td.ChatListMain(), order: 100, isPinned: false, source: null)))
        ..debugHandleUpdate(const td.UpdateChatPosition(
            chatId: 2, position: td.ChatPosition(list: td.ChatListMain(), order: 200, isPinned: false, source: null)))
        ..debugHandleUpdate(const td.UpdateChatPosition(
            chatId: 3, position: td.ChatPosition(list: td.ChatListMain(), order: 50, isPinned: true, source: null)))
        ..debugHandleUpdate(const td.UpdateChatTitle(chatId: 1, title: 'Renamed'));
      expect(account.chatList(const td.ChatListMain()).map((c) => c.id), [3, 2, 1]);
      expect(account.chats[1]!.title, 'Renamed');

      // Removing a chat from a list (order 0) drops it; archive is tracked separately.
      account
        ..debugHandleUpdate(const td.UpdateChatPosition(
            chatId: 2, position: td.ChatPosition(list: td.ChatListMain(), order: 0, isPinned: false, source: null)))
        ..debugHandleUpdate(const td.UpdateChatPosition(
            chatId: 2, position: td.ChatPosition(list: td.ChatListArchive(), order: 300, isPinned: false, source: null)));
      expect(account.chatList(const td.ChatListMain()).map((c) => c.id), [3, 1]);
      expect(account.chatList(const td.ChatListArchive()).map((c) => c.id), [2]);

      // Nullable fields can be cleared (patched through JSON).
      account.debugHandleUpdate(td.UpdateChatPhoto(chatId: 1, photo: null));
      expect(account.chats[1]!.photo, isNull);
      account.debugHandleUpdate(const td.UpdateChatReadInbox(chatId: 1, lastReadInboxMessageId: 10, unreadCount: 4));
      expect(account.chats[1]!.unreadCount, 4);
    }, skip: skip);
  });
}
