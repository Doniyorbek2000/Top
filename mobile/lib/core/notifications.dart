import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../l10n/strings.dart';
import '../state/telegram.dart';
import 'formatters.dart';

/// Local notifications for messages that arrive while the app is running but the chat is not on screen.
///
/// Delivery while the app is killed needs push notifications (Firebase / APNs + TDLib registerDevice),
/// which require project-specific credentials; see README.
class MessageNotifier {
  MessageNotifier._();

  static final MessageNotifier instance = MessageNotifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  void Function(int chatId)? onOpenChat;

  Future<void> initialize() async {
    if (_initialized || !(Platform.isAndroid || Platform.isIOS)) return;
    _initialized = true;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (response) {
          final chatId = int.tryParse(response.payload ?? '');
          if (chatId != null) onOpenChat?.call(chatId);
        },
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } on Object catch (error) {
      debugPrint('notifications init failed: $error');
    }
  }

  Future<void> showMessage({
    required TelegramAccount account,
    required td.Message message,
    required Strings strings,
    required bool showPreview,
  }) async {
    if (!_initialized) return;
    final chat = account.chats[message.chatId];
    if (chat == null) return;
    final title = chatTitle(chat, account, strings);
    final sender = account.isGroup(chat) ? '${account.senderName(message.senderId)}: ' : '';
    final body = showPreview ? '$sender${messagePreview(message, account, strings)}' : strings.t('new_message_notification');
    try {
      await _plugin.show(
        id: message.chatId.hashCode & 0x7FFFFFFF,
        title: title,
        body: body,
        payload: '${message.chatId}',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'messages',
            'Messages',
            channelDescription: 'New messages',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } on Object catch (error) {
      debugPrint('notification failed: $error');
    }
  }

  Future<void> cancelChat(int chatId) async {
    if (!_initialized) return;
    await _plugin.cancel(id: chatId.hashCode & 0x7FFFFFFF);
  }
}
