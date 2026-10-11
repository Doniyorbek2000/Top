import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';

class ChatTile extends ConsumerWidget {
  const ChatTile({super.key, required this.chatId, required this.list, required this.onTap, this.selected = false});

  final int chatId;
  final td.ChatList list;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider(chatId));
    if (chat == null) return const SizedBox.shrink();
    final account = ref.watch(accountProvider);
    final s = context.s;
    final theme = Theme.of(context);
    final colors = context.chatColors;
    final position = account.positionIn(chat, list);
    final last = chat.lastMessage;
    final muted = account.isMuted(chat);
    final actionText = chatActionText(chat, account, s);
    final draft = chat.draftMessage?.content;
    final hint = theme.hintColor;

    Widget subtitle;
    if (actionText != null) {
      subtitle = Text(actionText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: theme.colorScheme.primary));
    } else if (draft is td.DraftMessageContentText && draft.text.text.isNotEmpty) {
      subtitle = Text.rich(
        TextSpan(children: [
          TextSpan(text: '${s.t('draft')}: ', style: TextStyle(color: theme.colorScheme.error)),
          TextSpan(text: draft.text.text.replaceAll('\n', ' ')),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: hint),
      );
    } else if (last != null) {
      final preview = messagePreview(last, account, s).replaceAll('\n', ' ');
      String? author;
      if (account.isGroup(chat) && !isServiceMessage(last)) {
        author = last.isOutgoing ? s.t('you') : account.senderName(last.senderId).split(' ').first;
      }
      subtitle = Text.rich(
        TextSpan(children: [
          if (author != null && author.isNotEmpty)
            TextSpan(text: '$author: ', style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.85))),
          TextSpan(text: preview),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: hint),
      );
    } else {
      subtitle = const SizedBox.shrink();
    }

    final unread = chat.unreadCount > 0 || chat.isMarkedAsUnread;
    final trailingBadges = <Widget>[
      if (chat.unreadMentionCount > 0) _Badge(text: '@', color: theme.colorScheme.primary),
      if (chat.unreadReactionCount > 0) _Badge(text: '❤', color: Colors.redAccent),
      if (unread)
        _Badge(
          text: chat.unreadCount > 0 ? formatCount(chat.unreadCount) : '',
          color: muted ? colors.mutedBadge : colors.unreadBadge,
        )
      else if (position?.isPinned ?? false)
        Icon(Icons.push_pin_rounded, size: 18, color: hint),
    ];

    return Material(
      color: selected ? theme.colorScheme.primary.withValues(alpha: 0.12) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => showChatActions(context, ref, chat, list),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 14, 7),
          child: Row(
            children: [
              ChatAvatar(chatId: chat.id, size: 56),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        if (account.isChannel(chat))
                          Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.campaign_rounded, size: 17, color: hint))
                        else if (account.isGroup(chat))
                          Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.group_rounded, size: 17, color: hint))
                        else if (chat.type is td.ChatTypeSecret)
                          const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.lock_rounded, size: 15, color: Colors.green)),
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  chatTitle(chat, account, s),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16.5),
                                ),
                              ),
                              if (_isVerified(account, chat))
                                Padding(
                                  padding: const EdgeInsets.only(left: 3),
                                  child: Icon(Icons.verified_rounded, size: 16, color: theme.colorScheme.primary),
                                ),
                              if (muted)
                                Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.volume_off_rounded, size: 15, color: hint)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (last != null && last.isOutgoing && !account.isSavedMessages(chat))
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: _OutgoingStatus(message: last, chat: chat),
                          ),
                        if (last != null)
                          Text(
                            formatChatTime(last.date, s.locale),
                            style: TextStyle(fontSize: 13, color: unread && !muted ? theme.colorScheme.primary : hint),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: subtitle),
                        ...trailingBadges.map((b) => Padding(padding: const EdgeInsets.only(left: 4), child: b)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static bool _isVerified(TelegramAccount account, td.Chat chat) {
    final status = account.privateUser(chat)?.verificationStatus ?? account.supergroupOf(chat)?.verificationStatus;
    return status?.isVerified ?? false;
  }
}

class _OutgoingStatus extends StatelessWidget {
  const _OutgoingStatus({required this.message, required this.chat});

  final td.Message message;
  final td.Chat chat;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final state = message.sendingState;
    if (state is td.MessageSendingStateFailed) return const Icon(Icons.error_rounded, size: 16, color: Colors.redAccent);
    if (state is td.MessageSendingStatePending) return Icon(Icons.schedule_rounded, size: 15, color: Theme.of(context).hintColor);
    final read = message.id <= chat.lastReadOutboxMessageId;
    return Icon(read ? Icons.done_all_rounded : Icons.done_rounded, size: 17, color: color);
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 22),
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(11)),
        alignment: Alignment.center,
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
      );
}

Future<void> showChatActions(BuildContext context, WidgetRef ref, td.Chat chat, td.ChatList list) async {
  final account = ref.read(accountProvider);
  final s = context.s;
  final pinned = account.positionIn(chat, list)?.isPinned ?? false;
  final muted = account.isMuted(chat);
  final archived = account.isArchived(chat);
  final unread = chat.unreadCount > 0 || chat.isMarkedAsUnread;
  final isPrivate = account.privateUser(chat) != null;
  final hidden = ref.read(settingsProvider).hiddenChatIds.contains(chat.id);
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded),
            title: Text(s.t(pinned ? 'unpin' : 'pin')),
            onTap: () => Navigator.pop(context, 'pin'),
          ),
          ListTile(
            leading: Icon(muted ? Icons.volume_up_rounded : Icons.volume_off_rounded),
            title: Text(s.t(muted ? 'unmute' : 'mute')),
            onTap: () => Navigator.pop(context, 'mute'),
          ),
          ListTile(
            leading: Icon(archived ? Icons.unarchive_rounded : Icons.archive_rounded),
            title: Text(s.t(archived ? 'unarchive' : 'archive')),
            onTap: () => Navigator.pop(context, 'archive'),
          ),
          ListTile(
            leading: Icon(hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded),
            title: Text(s.t(hidden ? 'unhide_chat' : 'hide_chat')),
            onTap: () => Navigator.pop(context, 'hide'),
          ),
          ListTile(
            leading: Icon(unread ? Icons.mark_chat_read_rounded : Icons.mark_chat_unread_rounded),
            title: Text(s.t(unread ? 'mark_read' : 'mark_unread')),
            onTap: () => Navigator.pop(context, 'read'),
          ),
          ListTile(
            leading: Icon(Icons.delete_rounded, color: Theme.of(context).colorScheme.error),
            title: Text(
              s.t(isPrivate || account.isSavedMessages(chat) ? 'delete_chat' : (account.isChannel(chat) ? 'leave_channel' : 'leave_group')),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case 'pin':
      await guard(context, () => account.togglePinned(chat, list));
    case 'mute':
      await guard(context, () => account.setMuted(chat, muted ? 0 : muteForever));
    case 'archive':
      await guard(context, () => account.setArchived(chat, !archived));
    case 'read':
      await guard(context, () => unread ? account.markRead(chat) : account.markUnread(chat));
    case 'hide':
      ref.read(settingsProvider.notifier).setHidden(chat.id, !hidden);
      showToast(context, s.t(hidden ? 'chat_unhidden' : 'chat_hidden'));
    case 'delete':
      final ok = await confirm(
        context,
        title: s.t('delete_chat_confirm_title'),
        message: s.t('delete_chat_confirm', {'name': chatTitle(chat, account, s)}),
        confirmLabel: s.t('delete'),
        destructive: true,
      );
      if (ok && context.mounted) await guard(context, () => account.deleteChat(chat));
  }
}
