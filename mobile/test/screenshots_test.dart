// Renders key screens with realistic data into test/screenshots/*.png for visual review.
//   SADO_SCREENSHOTS=1 TDJSON_PATH=/path/to/libtdjson.so flutter test test/screenshots_test.dart --update-goldens
@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sado/app.dart';
import 'package:sado/core/app_lock.dart';
import 'package:sado/core/config.dart';
import 'package:sado/core/theme.dart';
import 'package:sado/features/auth/auth_screens.dart';
import 'package:sado/features/chat/chat_screen.dart';
import 'package:sado/features/home/home_screen.dart';
import 'package:sado/features/settings/settings_screen.dart';
import 'package:sado/features/settings/wallpaper.dart';
import 'package:sado/l10n/strings.dart';
import 'package:sado/state/actions.dart';
import 'package:sado/state/chat_history.dart';
import 'package:sado/state/providers.dart';
import 'package:sado/state/settings.dart';
import 'package:sado/state/telegram.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tdlib_ex/td_api.dart' as td;

final _enabled = Platform.environment['SADO_SCREENSHOTS'] == '1' && (Platform.environment['TDJSON_PATH'] ?? '').isNotEmpty;
final _now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
const _me = 100;

Map<String, dynamic> _file(int id) => {
      '@type': 'file',
      'id': id,
      'size': 48000,
      'expected_size': 48000,
      'local': {'@type': 'localFile', 'path': '', 'can_be_downloaded': true, 'is_downloading_completed': false},
      'remote': {'@type': 'remoteFile', 'id': 'r$id', 'unique_id': 'u$id', 'is_uploading_completed': true},
    };

td.User _user(int id, String first, String last, {bool online = false, int? lastSeen, bool bot = false}) => td.User.fromJson({
      '@type': 'user',
      'id': id,
      'first_name': first,
      'last_name': last,
      'phone_number': '99890${id.toString().padLeft(7, '0')}',
      'status': online
          ? {'@type': 'userStatusOnline', 'expires': _now + 600}
          : {'@type': 'userStatusOffline', 'was_online': lastSeen ?? _now - 3600},
      'is_contact': true,
      'type': bot ? {'@type': 'userTypeBot'} : {'@type': 'userTypeRegular'},
      'usernames': {'@type': 'usernames', 'active_usernames': ['${first.toLowerCase()}_$id'], 'disabled_usernames': [], 'editable_username': first.toLowerCase()},
    })!;

Map<String, dynamic> _chatJson(int id, String title, Map<String, dynamic> type, {int unread = 0, int muteFor = 0}) => {
      '@type': 'chat',
      'id': id,
      'type': type,
      'title': title,
      'permissions': {'@type': 'chatPermissions', 'can_send_basic_messages': true},
      'positions': <Object>[],
      'chat_lists': <Object>[],
      'notification_settings': {'@type': 'chatNotificationSettings', 'mute_for': muteFor},
      'available_reactions': {'@type': 'chatAvailableReactionsAll', 'max_reaction_count': 11},
      'video_chat': {'@type': 'videoChat', 'group_call_id': 0, 'has_participants': false},
      'unread_count': unread,
      'last_read_outbox_message_id': 1000000,
      'client_data': '',
    };

Map<String, dynamic> _text(String text) => {
      '@type': 'messageText',
      'text': {'@type': 'formattedText', 'text': text, 'entities': <Object>[]},
    };

td.Message _message(int id, int chatId, int senderId, Map<String, dynamic> content, {required int minutesAgo, Map<String, dynamic>? reactions, int? replyTo}) =>
    td.Message.fromJson({
      '@type': 'message',
      'id': id,
      'sender_id': {'@type': 'messageSenderUser', 'user_id': senderId},
      'chat_id': chatId,
      'is_outgoing': senderId == _me,
      'date': _now - minutesAgo * 60,
      'edit_date': 0,
      'content': content,
      'interaction_info': reactions == null
          ? null
          : {
              '@type': 'messageInteractionInfo',
              'view_count': 0,
              'forward_count': 0,
              'reactions': {'@type': 'messageReactions', 'reactions': [reactions], 'are_tags': false, 'paid_reactors': <Object>[]},
            },
      'reply_to': replyTo == null ? null : {'@type': 'messageReplyToMessage', 'chat_id': chatId, 'message_id': replyTo},
    })!;

Future<void> _loadFonts() async {
  final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/sdk/flutter'}/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final name in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto-Italic.ttf']) {
    final bytes = File('$fonts/$name').readAsBytesSync();
    roboto.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.view(File('$fonts/MaterialIcons-Regular.otf').readAsBytesSync().buffer)));
  await icons.load();
}

void main() {
  late TelegramAccount account;
  late Directory dir;
  late SharedPreferences prefs;

  setUpAll(() async {
    if (!_enabled) return;
    await _loadFonts();
    await initializeDateFormatting();
    SharedPreferences.setMockInitialValues({'locale': 'uz', 'translateTo': 'uz'});
    prefs = await SharedPreferences.getInstance();
    dir = await Directory.systemTemp.createTemp('sado_shots_');
    account = await TelegramAccount.startAt(dir.path, const TelegramCredentials(1, '0123456789abcdef0123456789abcdef'));

    void add(td.TdObject update) => account.debugHandleUpdate(update);
    add(const td.UpdateOption(name: 'my_id', value: td.OptionValueInteger(value: _me)));
    for (final user in [
      _user(_me, 'Doniyor', 'Rahimov', online: true),
      _user(1, 'Aziza', 'Karimova', online: true),
      _user(2, 'Jasur', 'Toshmatov', lastSeen: _now - 1800),
      _user(3, 'Malika', 'Yusupova', online: true),
      _user(4, 'Bobur', 'Aliyev', lastSeen: _now - 90000),
      _user(5, 'Sado Bot', '', bot: true),
      _user(6, 'Nodira', 'Saidova', lastSeen: _now - 300),
    ]) {
      add(td.UpdateUser(user: user));
    }
    add(td.UpdateSupergroup(supergroup: td.Supergroup.fromJson({
      '@type': 'supergroup', 'id': 77, 'member_count': 128400, 'is_channel': true,
      'status': {'@type': 'chatMemberStatusMember', 'member_until_date': 0},
    })!));
    add(td.UpdateBasicGroup(basicGroup: td.BasicGroup.fromJson({
      '@type': 'basicGroup', 'id': 55, 'member_count': 14, 'is_active': true,
      'status': {'@type': 'chatMemberStatusMember', 'member_until_date': 0},
    })!));

    final chats = <(Map<String, dynamic>, td.Message, int, bool)>[
      (_chatJson(1, 'Aziza Karimova', {'@type': 'chatTypePrivate', 'user_id': 1}, unread: 2),
          _message(11, 1, 1, _text('Ertaga soat 10 da uchrashamizmi? 🙂'), minutesAgo: 3), 900, true),
      (_chatJson(55, 'Oila 👨‍👩‍👧', {'@type': 'chatTypeBasicGroup', 'basic_group_id': 55}, unread: 5),
          _message(21, 55, 3, _text('Bugun kechki ovqatga hamma keladimi?'), minutesAgo: 12), 800, false),
      (_chatJson(77, 'Sado Yangiliklari', {'@type': 'chatTypeSupergroup', 'supergroup_id': 77, 'is_channel': true}, unread: 34, muteFor: muteForever),
          _message(31, 77, 77, _text('Sado 1.0 chiqdi: papkalar, ghost rejim, AI tarjima va boshqalar.'), minutesAgo: 45), 700, false),
      (_chatJson(2, 'Jasur Toshmatov', {'@type': 'chatTypePrivate', 'user_id': 2}),
          _message(41, 2, _me, _text('Hujjatlarni yubordim, ko\'rib chiqing'), minutesAgo: 70), 600, false),
      (_chatJson(_me, 'Doniyor Rahimov', {'@type': 'chatTypePrivate', 'user_id': _me}),
          _message(51, _me, _me, _text('https://github.com/tdlib/td'), minutesAgo: 300), 500, false),
      (_chatJson(4, 'Bobur Aliyev', {'@type': 'chatTypePrivate', 'user_id': 4}),
          _message(61, 4, 4, {
            '@type': 'messageVoiceNote',
            'voice_note': {'@type': 'voiceNote', 'duration': 14, 'waveform': encodeWaveform([for (var i = 0; i < 60; i++) (i * 13) % 32]), 'mime_type': 'audio/ogg', 'voice': _file(9)},
            'caption': {'@type': 'formattedText', 'text': '', 'entities': <Object>[]},
            'is_listened': false,
          }, minutesAgo: 1500), 400, false),
    ];
    add(td.UpdateNewChat(chat: td.Chat.fromJson(_chatJson(5, 'Sado Bot', {'@type': 'chatTypePrivate', 'user_id': 5}))!));
    add(td.UpdateNewChat(chat: td.Chat.fromJson(_chatJson(6, 'Nodira Saidova', {'@type': 'chatTypePrivate', 'user_id': 6}))!));
    for (final (json, last, order, pinned) in chats) {
      add(td.UpdateNewChat(chat: td.Chat.fromJson(json)!));
      add(td.UpdateChatLastMessage(chatId: json['id'] as int, lastMessage: last, positions: [
        td.ChatPosition(list: const td.ChatListMain(), order: order, isPinned: pinned, source: null),
      ]));
    }
    add(td.UpdateChatFolders(chatFolders: [
      for (final (id, name) in [(1, 'Shaxsiy'), (2, 'Ish'), (3, 'Kanallar')])
        td.ChatFolderInfo.fromJson({
          '@type': 'chatFolderInfo', 'id': id,
          'name': {'@type': 'chatFolderName', 'text': {'@type': 'formattedText', 'text': name, 'entities': <Object>[]}, 'animate_custom_emoji': false},
          'icon': {'@type': 'chatFolderIcon', 'name': 'Custom'}, 'color_id': -1,
        })!,
    ], mainChatListPosition: 0, areTagsEnabled: false));
    add(const td.UpdateUnreadMessageCount(chatList: td.ChatListMain(), unreadCount: 41, unreadUnmutedCount: 7));
    await Future<void>.delayed(Duration.zero);
  });

  tearDownAll(() async {
    if (!_enabled) return;
    await account.dispose();
    await dir.delete(recursive: true);
  });

  Future<void> shoot(WidgetTester tester, String name, Widget screen, {Brightness brightness = Brightness.light, bool withAccount = true}) async {
    // Draw real shadows instead of the test framework's debug outlines.
    debugDisableShadows = false;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (withAccount) accountProvider.overrideWithValue(account),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(brightness, accentPalette.first),
        locale: const Locale('uz'),
        supportedLocales: const [Locale('uz'), Locale('ru'), Locale('en')],
        localizationsDelegates: const [StringsDelegate(), GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
        home: RepaintBoundary(child: screen),
      ),
    ));
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        await precacheImage((element.widget as Image).image, element);
      }
    });
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile('screenshots/$name.png'));
    // The test binding verifies debug painting flags are restored before tear-down.
    debugDisableShadows = true;
  }

  testWidgets('home', (tester) async => shoot(tester, 'home', const HomeScreen()), skip: !_enabled);

  testWidgets('home dark', (tester) async => shoot(tester, 'home_dark', const HomeScreen(), brightness: Brightness.dark), skip: !_enabled);

  testWidgets('drawer', (tester) async {
    await shoot(tester, 'drawer_closed', const HomeScreen());
    final state = tester.firstState<ScaffoldState>(find.byType(Scaffold));
    state.openDrawer();
    debugDisableShadows = false;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile('screenshots/drawer.png'));
    debugDisableShadows = true;
  }, skip: !_enabled);

  ChatHistory history(int chatId, List<td.Message> messages) {
    final h = ChatHistory(account, chatId, ghostMode: true)
      ..messages.addAll(messages.reversed)
      ..initialized = true
      ..hasOlder = false;
    return h;
  }

  testWidgets('private chat', (tester) async {
    final h = history(1, [
      _message(1, 1, 1, _text('Salom! Qalaysiz?'), minutesAgo: 60 * 26),
      _message(2, 1, _me, _text('Assalomu alaykum, yaxshi rahmat. O\'zingiz-chi?'), minutesAgo: 60 * 26 - 2),
      _message(3, 1, 1, _text('Men ham yaxshi. Loyiha qanday ketyapti?'), minutesAgo: 30),
      _message(4, 1, _me, _text('Zo\'r! Sado ilovasining birinchi versiyasi tayyor: Telegram bilan to\'liq ishlaydi.'), minutesAgo: 28,
          reactions: {'@type': 'messageReaction', 'type': {'@type': 'reactionTypeEmoji', 'emoji': '🔥'}, 'total_count': 2, 'is_chosen': false, 'recent_sender_ids': <Object>[]}),
      _message(5, 1, 1, {
        '@type': 'messageVoiceNote',
        'voice_note': {'@type': 'voiceNote', 'duration': 23, 'waveform': encodeWaveform([for (var i = 0; i < 70; i++) ((i * 7) % 29) + 2]), 'mime_type': 'audio/ogg', 'voice': _file(10)},
        'caption': {'@type': 'formattedText', 'text': '', 'entities': <Object>[]},
        'is_listened': false,
      }, minutesAgo: 6),
      _message(6, 1, 1, _text('Ertaga soat 10 da uchrashamizmi? 🙂'), minutesAgo: 3, replyTo: 4),
    ]);
    await shoot(tester, 'chat', ChatScreen(chatId: 1, debugHistory: h));
  }, skip: !_enabled);

  testWidgets('group chat with poll', (tester) async {
    final h = history(55, [
      _message(1, 55, 3, _text('Bugun kechki ovqatga hamma keladimi?'), minutesAgo: 40),
      _message(2, 55, 2, _text('Men kelaman, 19:00 da'), minutesAgo: 38),
      _message(3, 55, _me, {
        '@type': 'messagePoll',
        'poll': {
          '@type': 'poll', 'id': 1,
          'question': {'@type': 'formattedText', 'text': 'Nima tayyorlaymiz?', 'entities': <Object>[]},
          'options': [
            for (final (text, pct, chosen) in [('Osh', 62, true), ('Manti', 25, false), ('Lag\'mon', 13, false)])
              {'@type': 'pollOption', 'id': text, 'text': {'@type': 'formattedText', 'text': text, 'entities': <Object>[]}, 'voter_count': pct, 'vote_percentage': pct, 'is_chosen': chosen},
          ],
          'total_voter_count': 8, 'is_anonymous': true, 'type': {'@type': 'pollTypeRegular'},
        },
        'description': {'@type': 'formattedText', 'text': '', 'entities': <Object>[]},
      }, minutesAgo: 35),
      _message(4, 55, 3, _text('Osh bo\'lsa zo\'r bo\'lardi 😋'), minutesAgo: 12),
    ]);
    await shoot(tester, 'group', ChatScreen(chatId: 55, debugHistory: h));
  }, skip: !_enabled);

  testWidgets('bot chat with keyboard and formatting', (tester) async {
    Map<String, dynamic> entity(int offset, int length, Map<String, dynamic> type) => {'@type': 'textEntity', 'offset': offset, 'length': length, 'type': type};
    Map<String, dynamic> button(String text, Map<String, dynamic> type) => {'@type': 'inlineKeyboardButton', 'text': text, 'icon_custom_emoji_id': 0, 'style': {'@type': 'buttonStyleDefault'}, 'type': type};
    const welcome = 'Xush kelibsiz! Bu bot buyurtmalarni qabul qiladi. Batafsil: sado.uz';
    final botMessage = td.Message.fromJson({
      ..._message(2, 5, 5, {
        '@type': 'messageText',
        'text': {
          '@type': 'formattedText',
          'text': welcome,
          'entities': [
            entity(0, 13, {'@type': 'textEntityTypeBold'}),
            entity(37, 21, {'@type': 'textEntityTypeItalic'}),
            entity(welcome.length - 7, 7, {'@type': 'textEntityTypeUrl'}),
          ],
        },
      }, minutesAgo: 4).toJson(),
      'reply_markup': {
        '@type': 'replyMarkupInlineKeyboard',
        'rows': [
          [button('🛒 Buyurtma berish', {'@type': 'inlineKeyboardButtonTypeCallback', 'data': 'b3JkZXI='}), button('📋 Menyu', {'@type': 'inlineKeyboardButtonTypeCallback', 'data': 'bWVudQ=='})],
          [button('Ilovani ochish', {'@type': 'inlineKeyboardButtonTypeWebApp', 'url': 'https://sado.uz'})],
          [button('Saytga o\'tish', {'@type': 'inlineKeyboardButtonTypeUrl', 'url': 'https://sado.uz'})],
        ],
      },
    })!;
    final h = history(5, [_message(1, 5, _me, _text('/start'), minutesAgo: 5), botMessage]);
    await shoot(tester, 'bot', ChatScreen(chatId: 5, debugHistory: h));
  }, skip: !_enabled);

  testWidgets('empty private chat', (tester) async {
    await shoot(tester, 'empty_chat', ChatScreen(chatId: 6, debugHistory: history(6, const [])));
  }, skip: !_enabled);

  testWidgets('passcode lock', (tester) async {
    await shoot(tester, 'lock', Scaffold(body: SafeArea(child: PinPad(title: 'PIN kodni kiriting', pin: '12', onChanged: (_) {}))));
  }, skip: !_enabled);

  testWidgets('chat background', (tester) async => shoot(tester, 'wallpaper', const WallpaperScreen()), skip: !_enabled);

  testWidgets('settings', (tester) async => shoot(tester, 'settings', const SettingsScreen()), skip: !_enabled);

  testWidgets('login phone', (tester) async => shoot(tester, 'login', const PhoneScreen()), skip: !_enabled);

  testWidgets('api keys', (tester) async => shoot(tester, 'api_keys', const CredentialsScreen(), withAccount: false), skip: !_enabled);

  // Keeps the import of the app shell compiling in this file.
  test('app shell exists', () => expect(SadoApp, isNotNull));
}
