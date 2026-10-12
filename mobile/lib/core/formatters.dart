import 'package:intl/intl.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../l10n/strings.dart';
import '../state/telegram.dart';

DateTime fromUnix(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

String formatChatTime(int unixSeconds, String locale) {
  final time = fromUnix(unixSeconds);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return DateFormat.Hm(locale).format(time);
  if (diff < 7) return DateFormat.E(locale).format(time);
  if (time.year == now.year) return DateFormat('d MMM', locale).format(time);
  return DateFormat('dd.MM.yy', locale).format(time);
}

String formatTime(int unixSeconds, String locale) => DateFormat.Hm(locale).format(fromUnix(unixSeconds));

bool isSameDay(int a, int b) {
  final x = fromUnix(a);
  final y = fromUnix(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

String formatDayHeader(int unixSeconds, Strings s) {
  final time = fromUnix(unixSeconds);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return s.t('today');
  if (diff == 1) return s.t('yesterday');
  if (time.year == now.year) return DateFormat('d MMMM', s.locale).format(time);
  return DateFormat('d MMMM y', s.locale).format(time);
}

String formatDuration(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (duration.inHours > 0) return '${duration.inHours}:$minutes:$seconds';
  return '${duration.inMinutes}:$seconds';
}

String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatCount(int count) {
  if (count < 1000) return '$count';
  if (count < 1000000) return '${(count / 1000).toStringAsFixed(count < 10000 ? 1 : 0)}K';
  return '${(count / 1000000).toStringAsFixed(1)}M';
}

bool isOnline(td.User? user) =>
    user?.status is td.UserStatusOnline &&
    (user!.status as td.UserStatusOnline).expires * 1000 > DateTime.now().millisecondsSinceEpoch;

String formatUserStatus(td.User user, Strings s) {
  if (user.type is td.UserTypeBot) return s.t('bot');
  if (user.type is td.UserTypeDeleted) return s.t('deleted_account');
  if (user.isSupport) return s.t('support');
  final status = user.status;
  switch (status) {
    case td.UserStatusOnline():
      if (isOnline(user)) return s.t('online');
      return s.t('last_seen_recently');
    case td.UserStatusOffline(:final wasOnline):
      final seen = fromUnix(wasOnline);
      final diff = DateTime.now().difference(seen);
      if (diff.inMinutes < 1) return s.t('last_seen_just_now');
      if (diff.inMinutes < 60) return s.t('last_seen_minutes', {'n': '${diff.inMinutes}'});
      final now = DateTime.now();
      if (seen.year == now.year && seen.month == now.month && seen.day == now.day) {
        return s.t('last_seen_today', {'time': formatTime(wasOnline, s.locale)});
      }
      final yesterday = now.subtract(const Duration(days: 1));
      if (seen.year == yesterday.year && seen.month == yesterday.month && seen.day == yesterday.day) {
        return s.t('last_seen_yesterday', {'time': formatTime(wasOnline, s.locale)});
      }
      return s.t('last_seen_date', {'date': DateFormat('dd.MM.yy', s.locale).format(seen)});
    case td.UserStatusRecently():
      return s.t('last_seen_recently');
    case td.UserStatusLastWeek():
      return s.t('last_seen_week');
    case td.UserStatusLastMonth():
      return s.t('last_seen_month');
    default:
      return s.t('last_seen_long_ago');
  }
}

/// Subtitle under a chat title: presence for users, member counts for groups and channels.
String chatSubtitle(td.Chat chat, TelegramAccount account, Strings s) {
  if (account.isSavedMessages(chat)) return '';
  final user = account.privateUser(chat);
  if (user != null) return formatUserStatus(user, s);
  final members = account.memberCount(chat);
  if (account.isChannel(chat)) return s.count('subscribers', members);
  final online = account.onlineMemberCounts[chat.id] ?? 0;
  final base = s.count('members', members);
  return online > 1 ? '$base, ${s.t('n_online', {'n': '$online'})}' : base;
}

String chatTitle(td.Chat chat, TelegramAccount account, Strings s) {
  if (account.isSavedMessages(chat)) return s.t('saved_messages');
  final user = account.privateUser(chat);
  if (user != null && user.type is td.UserTypeDeleted) return s.t('deleted_account');
  return chat.title.isEmpty ? s.t('deleted_account') : chat.title;
}

td.FormattedText? captionOf(td.MessageContent content) => switch (content) {
      td.MessagePhoto(:final caption) => caption,
      td.MessageVideo(:final caption) => caption,
      td.MessageDocument(:final caption) => caption,
      td.MessageAudio(:final caption) => caption,
      td.MessageAnimation(:final caption) => caption,
      td.MessageVoiceNote(:final caption) => caption,
      _ => null,
    };

/// Plain text of a message (text or caption), used for copy, search, translation.
String messageText(td.Message message) => switch (message.content) {
      td.MessageText(:final text) => text.text,
      final content => captionOf(content)?.text ?? '',
    };

String _withCaption(String icon, String label, td.FormattedText? caption) {
  final text = caption?.text.trim() ?? '';
  return text.isEmpty ? '$icon $label' : '$icon $text';
}

/// One-line preview for chat lists, reply bars and notifications.
String messagePreview(td.Message message, TelegramAccount account, Strings s) =>
    contentPreview(message.content, s) ?? serviceMessageText(message, account, s) ?? s.t('unsupported_message');

/// Preview of message content alone (also used for replies whose original message is not loaded).
String? contentPreview(td.MessageContent content, Strings s) {
  switch (content) {
    case td.MessageText(:final text):
      return text.text;
    case td.MessagePhoto(:final caption):
      return _withCaption('🖼', s.t('photo'), caption);
    case td.MessageVideo(:final caption):
      return _withCaption('🎬', s.t('video'), caption);
    case td.MessageAnimation(:final caption):
      return _withCaption('🎞', 'GIF', caption);
    case td.MessageVoiceNote(:final voiceNote):
      return '🎤 ${s.t('voice_message')} ${formatDuration(Duration(seconds: voiceNote.duration))}';
    case td.MessageVideoNote():
      return '⏺ ${s.t('video_message')}';
    case td.MessageAudio(:final audio, :final caption):
      final title = [audio.performer, audio.title].where((p) => p.isNotEmpty).join(' — ');
      return _withCaption('🎵', title.isEmpty ? s.t('audio') : title, caption);
    case td.MessageDocument(:final document, :final caption):
      return _withCaption('📎', document.fileName.isEmpty ? s.t('file') : document.fileName, caption);
    case td.MessageSticker(:final sticker):
      return '${sticker.emoji} ${s.t('sticker')}';
    case td.MessageAnimatedEmoji(:final emoji):
      return emoji;
    case td.MessageDice(:final emoji):
      return emoji;
    case td.MessageLocation() || td.MessageLiveLocation():
      return '📍 ${s.t('location')}';
    case td.MessageVenue(:final venue):
      return '📍 ${venue.title}';
    case td.MessageContact(:final contact):
      return '👤 ${'${contact.firstName} ${contact.lastName}'.trim()}';
    case td.MessagePoll(:final poll):
      return '📊 ${poll.question.text}';
    case td.MessageCall(:final isVideo, :final duration):
      final label = isVideo ? s.t('video_call') : s.t('voice_call');
      return duration > 0 ? '📞 $label (${formatDuration(Duration(seconds: duration))})' : '📞 $label';
    case td.MessageStory():
      return s.t('story');
    case td.MessageGame(:final game):
      return '🎮 ${game.title}';
    case td.MessageInvoice(:final productInfo):
      return '🧾 ${productInfo.title}';
    default:
      return null;
  }
}

/// Text for service messages (member joined, title changed...), or null for regular content.
String? serviceMessageText(td.Message message, TelegramAccount account, Strings s) {
  final actor = account.senderName(message.senderId);
  String names(List<int> ids) => ids.map(account.userName).where((n) => n.isNotEmpty).join(', ');
  return switch (message.content) {
    td.MessageBasicGroupChatCreate(:final title) => s.t('sys_group_created', {'actor': actor, 'title': title}),
    td.MessageSupergroupChatCreate(:final title) => _inChannel(account, message.chatId)
        ? s.t('sys_channel_created')
        : s.t('sys_group_created', {'actor': actor, 'title': title}),
    td.MessageChatAddMembers(:final memberUserIds) =>
      memberUserIds.length == 1 && account.senderKey(message.senderId) == memberUserIds.first
          ? s.t('sys_member_joined', {'actor': actor})
          : s.t('sys_members_added', {'actor': actor, 'users': names(memberUserIds)}),
    td.MessageChatJoinByLink() => s.t('sys_member_joined_link', {'actor': actor}),
    td.MessageChatJoinByRequest() => s.t('sys_member_joined', {'actor': actor}),
    td.MessageChatDeleteMember(:final userId) => account.senderKey(message.senderId) == userId
        ? s.t('sys_member_left', {'actor': actor})
        : s.t('sys_member_removed', {'actor': actor, 'users': account.userName(userId)}),
    td.MessageChatChangeTitle(:final title) => s.t('sys_title_changed', {'actor': actor, 'title': title}),
    td.MessageChatChangePhoto() => s.t('sys_photo_changed', {'actor': actor}),
    td.MessageChatDeletePhoto() => s.t('sys_photo_removed', {'actor': actor}),
    td.MessagePinMessage() => s.t('sys_message_pinned', {'actor': actor}),
    td.MessageContactRegistered() => s.t('sys_joined_telegram', {'actor': actor}),
    td.MessageChatUpgradeTo() || td.MessageChatUpgradeFrom() => s.t('sys_upgraded'),
    td.MessageScreenshotTaken() => s.t('sys_screenshot', {'actor': actor}),
    td.MessageChatSetMessageAutoDeleteTime(:final messageAutoDeleteTime) => messageAutoDeleteTime == 0
        ? s.t('sys_autodelete_off', {'actor': actor})
        : s.t('sys_autodelete_on', {'actor': actor}),
    td.MessageCustomServiceAction(:final text) => text,
    td.MessageGiftedPremium() => s.t('sys_gift'),
    _ => null,
  };
}

bool isServiceMessage(td.Message message) => switch (message.content) {
      td.MessageBasicGroupChatCreate() ||
      td.MessageSupergroupChatCreate() ||
      td.MessageChatAddMembers() ||
      td.MessageChatJoinByLink() ||
      td.MessageChatJoinByRequest() ||
      td.MessageChatDeleteMember() ||
      td.MessageChatChangeTitle() ||
      td.MessageChatChangePhoto() ||
      td.MessageChatDeletePhoto() ||
      td.MessagePinMessage() ||
      td.MessageContactRegistered() ||
      td.MessageChatUpgradeTo() ||
      td.MessageChatUpgradeFrom() ||
      td.MessageScreenshotTaken() ||
      td.MessageChatSetMessageAutoDeleteTime() ||
      td.MessageCustomServiceAction() ||
      td.MessageGiftedPremium() =>
        true,
      _ => false,
    };

bool _inChannel(TelegramAccount account, int chatId) {
  final chat = account.chats[chatId];
  return chat != null && account.isChannel(chat);
}

/// "Ali is typing…" style text for chat actions.
String? chatActionText(td.Chat chat, TelegramAccount account, Strings s) {
  final actions = account.chatActions[chat.id];
  if (actions == null || actions.isEmpty) return null;
  final first = actions.values.first;
  final key = switch (first.action) {
    td.ChatActionRecordingVoiceNote() => 'action_recording',
    td.ChatActionUploadingPhoto() => 'action_photo',
    td.ChatActionUploadingVideo() || td.ChatActionRecordingVideo() => 'action_video',
    td.ChatActionUploadingDocument() => 'action_file',
    td.ChatActionChoosingSticker() => 'action_sticker',
    _ => 'action_typing',
  };
  final verb = s.t(key);
  if (account.privateUser(chat) != null) return verb;
  final name = account.users[first.senderId]?.firstName ?? '';
  if (actions.length > 1) return s.t('action_several', {'n': '${actions.length}'});
  return '$name $verb';
}
