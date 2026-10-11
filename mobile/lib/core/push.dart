import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../l10n/strings.dart';
import '../state/telegram.dart';
import 'tdlib/td_client.dart';

/// Telegram push notifications over Firebase Cloud Messaging (Android).
///
/// Disabled unless the build contains a Firebase config (android/app/google-services.json) and
/// Telegram delivers pushes for this app's api_id. iOS needs a Notification Service Extension to
/// render Telegram's localized APNs payloads, so iOS registration stays off until that exists.
class PushService {
  PushService._();

  static final PushService instance = PushService._();

  bool _available = false;
  StreamSubscription<String>? _tokenRefresh;
  StreamSubscription<RemoteMessage>? _foreground;

  bool get isAvailable => _available;

  /// Called once from main(); never throws.
  Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
      _available = true;
    } on Object catch (error) {
      debugPrint('push disabled (no Firebase config): $error');
    }
  }

  /// Registers this device with Telegram for the logged-in account.
  Future<void> register(TelegramAccount account) async {
    if (!_available) return;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token == null) return;
      await _registerToken(account, token);
      await _tokenRefresh?.cancel();
      _tokenRefresh = messaging.onTokenRefresh.listen((fresh) => unawaited(_registerToken(account, fresh)));
      await _foreground?.cancel();
      // In the foreground TDLib is running: hand the payload to it and let normal updates drive the UI.
      _foreground = FirebaseMessaging.onMessage.listen((message) {
        unawaited(account
            .send<td.Ok>(td.ProcessPushNotification(payload: jsonEncode(message.data)))
            .catchError((Object _) => const td.Ok()));
      });
    } on Object catch (error) {
      debugPrint('push registration failed: $error');
    }
  }

  Future<void> _registerToken(TelegramAccount account, String token) async {
    try {
      await account.send<td.PushReceiverId>(td.RegisterDevice(
        deviceToken: td.DeviceTokenFirebaseCloudMessaging(token: token, encrypt: false),
        otherUserIds: const [],
      ));
    } on TdException catch (error) {
      debugPrint('registerDevice failed: $error');
    }
  }

  Future<void> dispose() async {
    await _tokenRefresh?.cancel();
    await _foreground?.cancel();
  }
}

/// Text of a Telegram push payload ({loc_key, loc_args, custom}) for a local notification.
class PushContent {
  const PushContent({required this.title, required this.body, required this.chatId});

  final String title;
  final String body;
  final int? chatId;

  static Map<String, dynamic> _payload(Map<String, dynamic> data) {
    final nested = data['data'];
    if (nested is String) {
      try {
        final decoded = jsonDecode(nested);
        if (decoded is Map) return decoded.cast<String, dynamic>();
      } on FormatException {
        return data;
      }
    }
    return data;
  }

  static List<String> _list(Object? value) {
    if (value is List) return value.map((e) => '$e').toList();
    if (value is String && value.startsWith('[')) {
      try {
        return (jsonDecode(value) as List).map((e) => '$e').toList();
      } on FormatException {
        return const [];
      }
    }
    return const [];
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is Map) return value.cast<String, dynamic>();
    if (value is String && value.startsWith('{')) {
      try {
        return (jsonDecode(value) as Map).cast<String, dynamic>();
      } on FormatException {
        return const {};
      }
    }
    return const {};
  }

  static const _mediaKeys = {
    'PHOTO': 'photo',
    'VIDEO': 'video',
    'ROUND': 'video_message',
    'DOC': 'file',
    'STICKER': 'sticker',
    'AUDIO': 'voice_message',
    'VOICE': 'voice_message',
    'GIF': 'gif',
    'GEO': 'location',
    'GEOLIVE': 'location',
    'CONTACT': 'contact',
    'POLL': 'poll',
  };

  /// Returns null for payloads that are not new-message notifications (read receipts, service pushes).
  static PushContent? parse(Map<String, dynamic> data, Strings s, {required bool showPreview}) {
    final payload = _payload(data);
    final key = payload['loc_key'] as String? ?? '';
    if (key.isEmpty) return null;
    final args = _list(payload['loc_args']);
    final custom = _map(payload['custom']);
    final isChat = key.startsWith('CHAT_');
    final isText = key.endsWith('_TEXT');
    final suffix = key.split('_').last;
    final media = _mediaKeys[suffix];
    String body;
    String title;
    if (isChat && args.length >= 2) {
      title = args[1];
      final content = isText && args.length >= 3 ? args[2] : (media != null ? s.t(media) : s.t('message'));
      body = '${args[0]}: $content';
    } else if (args.isNotEmpty) {
      title = args[0];
      body = isText && args.length >= 2 ? args[1] : (media != null ? s.t(media) : s.t('message'));
    } else {
      return null;
    }
    if (!showPreview) body = s.t('new_message_notification');
    int? chatId;
    final fromId = int.tryParse('${custom['from_id'] ?? ''}');
    final groupId = int.tryParse('${custom['chat_id'] ?? ''}');
    final channelId = int.tryParse('${custom['channel_id'] ?? ''}');
    if (channelId != null) {
      chatId = -1000000000000 - channelId;
    } else if (groupId != null) {
      chatId = -groupId;
    } else if (fromId != null) {
      chatId = fromId;
    }
    return PushContent(title: title, body: body, chatId: chatId);
  }
}

/// Runs in a background isolate when a push arrives while the app is not in the foreground.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  final prefs = await SharedPreferences.getInstance();
  if (!(prefs.getBool('notifications') ?? true)) return;
  final strings = Strings(prefs.getString('locale') ?? 'uz');
  // A locked app never reveals message text in notifications.
  final showPreview = (prefs.getBool('messagePreview') ?? true) && !(prefs.getBool('lock.enabled') ?? false);
  final content = PushContent.parse(message.data, strings, showPreview: showPreview);
  if (content == null) return;
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
  await plugin.show(
    // Same id scheme as MessageNotifier so a foreground notification for the chat is replaced, not duplicated.
    id: (content.chatId ?? content.title.hashCode).hashCode & 0x7FFFFFFF,
    title: content.title,
    body: content.body,
    payload: content.chatId?.toString(),
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'messages',
        'Messages',
        channelDescription: 'New messages',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
      ),
    ),
  );
}
