import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import 'message_content.dart';

/// Replied-to message, fetched on demand.
final repliedMessageProvider = FutureProvider.autoDispose.family<td.Message?, (int, int)>((ref, key) async {
  final account = ref.watch(accountProvider);
  try {
    return await account.send<td.Message>(td.GetMessage(chatId: key.$1, messageId: key.$2));
  } on TdException {
    return null;
  }
});

/// Text translations the user requested in this session (message id → translated text).
class TranslationsNotifier extends Notifier<Map<int, String>> {
  @override
  Map<int, String> build() => const {};

  void set(int messageId, String? text) {
    final next = Map.of(state);
    if (text == null) {
      next.remove(messageId);
    } else {
      next[messageId] = text;
    }
    state = next;
  }
}

final translationsProvider = NotifierProvider<TranslationsNotifier, Map<int, String>>(TranslationsNotifier.new);

class ServiceMessage extends ConsumerWidget {
  const ServiceMessage({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 32),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(14)),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w500)),
        ),
      );
}

class MessageBubble extends ConsumerWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.chat,
    required this.showSender,
    required this.showTail,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onReplyTap,
  });

  final td.Message message;
  final td.Chat chat;
  final bool showSender;
  final bool showTail;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final void Function(int messageId) onReplyTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final settings = ref.watch(settingsProvider);
    final translation = ref.watch(translationsProvider.select((t) => t[message.id]));
    final colors = context.chatColors;
    final outgoing = message.isOutgoing && !message.isChannelPost;
    final isChannel = account.isChannel(chat);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxWidth = screenWidth * (screenWidth > 600 ? 0.6 : 0.78);
    final content = message.content;
    final bareMedia = content is td.MessageSticker || content is td.MessageAnimatedEmoji || content is td.MessageDice ||
        content is td.MessageVideoNote;
    final isMediaBubble = content is td.MessagePhoto || content is td.MessageVideo || content is td.MessageAnimation;
    final text = switch (content) {
      td.MessageText(:final text) => text,
      _ => captionOf(content),
    };
    final hasText = text != null && text.text.isNotEmpty;
    final textColor = outgoing ? colors.outgoingText : colors.incomingText;
    final radius = Radius.circular(settings.bubbleRadius);
    final small = Radius.circular(settings.bubbleRadius / 3.5);
    final showGroupAvatar = !outgoing && account.isGroup(chat);

    Widget? senderLabel;
    if (showSender && !outgoing && (account.isGroup(chat) || isChannel && message.authorSignature != null)) {
      final name = isChannel ? (message.authorSignature ?? '') : account.senderName(message.senderId);
      final seed = account.senderKey(message.senderId);
      senderLabel = Text(
        name,
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: _nameColors[seed.abs() % _nameColors.length]),
      );
    }

    final children = <Widget>[
      if (senderLabel != null) Padding(padding: const EdgeInsets.fromLTRB(10, 6, 10, 0), child: senderLabel),
      if (message.forwardInfo != null) _ForwardHeader(info: message.forwardInfo!, outgoing: outgoing),
      if (message.replyTo case final td.MessageReplyToMessage reply)
        _ReplyHeader(reply: reply, outgoing: outgoing, onTap: () => onReplyTap(reply.messageId)),
      if (!bareMedia && content is! td.MessageText)
        Padding(
          padding: isMediaBubble ? EdgeInsets.zero : const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: ClipRRect(
            borderRadius: isMediaBubble && senderLabel == null && message.replyTo == null && message.forwardInfo == null
                ? BorderRadius.vertical(top: radius, bottom: hasText ? Radius.zero : radius)
                : BorderRadius.zero,
            child: MessageMedia(message: message, maxWidth: maxWidth),
          ),
        ),
      if (hasText)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: FormattedTextView(
            text: text,
            style: TextStyle(color: textColor, fontSize: 15.5 * settings.textScale, height: 1.3),
          ),
        ),
      if (translation != null)
        Container(
          margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          padding: const EdgeInsets.only(left: 8),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2))),
          child: Text(translation, style: TextStyle(color: textColor, fontSize: 15 * settings.textScale, fontStyle: FontStyle.italic)),
        ),
      Align(
        alignment: Alignment.bottomRight,
        child: Padding(padding: const EdgeInsets.fromLTRB(10, 2, 8, 5), child: _Footer(message: message, chat: chat, outgoing: outgoing, isChannel: isChannel)),
      ),
      if (message.interactionInfo?.reactions?.reactions.isNotEmpty ?? false)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: _Reactions(message: message, outgoing: outgoing),
        ),
    ];

    final bubble = bareMedia
        ? Column(
            crossAxisAlignment: outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (message.replyTo case final td.MessageReplyToMessage reply)
                _ReplyHeader(reply: reply, outgoing: outgoing, onTap: () => onReplyTap(reply.messageId)),
              MessageMedia(message: message, maxWidth: maxWidth),
              _Footer(message: message, chat: chat, outgoing: outgoing, isChannel: isChannel, onMedia: true),
            ],
          )
        : Container(
            constraints: BoxConstraints(maxWidth: maxWidth, minWidth: 80),
            decoration: BoxDecoration(
              color: outgoing ? colors.outgoingBubble : colors.incomingBubble,
              borderRadius: BorderRadius.only(
                topLeft: radius,
                topRight: radius,
                bottomLeft: outgoing || !showTail ? radius : small,
                bottomRight: outgoing && showTail ? small : radius,
              ),
              boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 1.5, offset: Offset(0, 1))],
            ),
            child: IntrinsicWidth(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
            ),
          );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      onDoubleTap: () => guard(context, () => account.toggleReaction(message, settings.quickReaction)),
      child: Container(
        color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.18) : Colors.transparent,
        padding: EdgeInsets.fromLTRB(showGroupAvatar ? 6 : 8, showTail ? 2 : 1, 8, showTail ? 4 : 1),
        child: Row(
          mainAxisAlignment: outgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (showGroupAvatar)
              SizedBox(
                width: 40,
                child: showTail && message.senderId is td.MessageSenderUser
                    ? UserAvatar(userId: (message.senderId as td.MessageSenderUser).userId, size: 34, showOnline: false)
                    : null,
              ),
            Flexible(child: bubble),
          ],
        ),
      ),
    );
  }

  static const _nameColors = [
    Color(0xFFE17076),
    Color(0xFFF39C3D),
    Color(0xFF9B6CE0),
    Color(0xFF4FAD4F),
    Color(0xFF3FB3C7),
    Color(0xFF3D8AD8),
    Color(0xFFD46BA4),
  ];
}

class _Footer extends StatelessWidget {
  const _Footer({required this.message, required this.chat, required this.outgoing, required this.isChannel, this.onMedia = false});

  final td.Message message;
  final td.Chat chat;
  final bool outgoing;
  final bool isChannel;
  final bool onMedia;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final color = onMedia ? Colors.white : context.metaColor(outgoing);
    final views = message.interactionInfo?.viewCount ?? 0;
    final style = TextStyle(fontSize: 11.5, color: color);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.isPinned) Padding(padding: const EdgeInsets.only(right: 3), child: Icon(Icons.push_pin_rounded, size: 12, color: color)),
        if (isChannel && views > 0) ...[
          Icon(Icons.visibility_rounded, size: 13, color: color),
          const SizedBox(width: 2),
          Text(formatCount(views), style: style),
          const SizedBox(width: 6),
        ],
        if (message.editDate > 0) Text('${s.t('edited')} ', style: style),
        Text(formatTime(message.date, s.locale), style: style),
        if (message.isOutgoing && !isChannel) ...[
          const SizedBox(width: 3),
          _statusIcon(color),
        ],
      ],
    );
    if (!onMedia) return row;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(10)),
      child: row,
    );
  }

  Widget _statusIcon(Color color) {
    final state = message.sendingState;
    if (state is td.MessageSendingStateFailed) return const Icon(Icons.error_rounded, size: 14, color: Colors.redAccent);
    if (state is td.MessageSendingStatePending) return Icon(Icons.schedule_rounded, size: 13, color: color);
    final read = message.id <= chat.lastReadOutboxMessageId;
    return Icon(read ? Icons.done_all_rounded : Icons.done_rounded, size: 15, color: color);
  }
}

class _ForwardHeader extends ConsumerWidget {
  const _ForwardHeader({required this.info, required this.outgoing});

  final td.MessageForwardInfo info;
  final bool outgoing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final name = switch (info.origin) {
      td.MessageOriginUser(:final senderUserId) => account.userName(senderUserId),
      td.MessageOriginChat(:final senderChatId) => account.chats[senderChatId]?.title ?? '',
      td.MessageOriginChannel(:final chatId) => account.chats[chatId]?.title ?? '',
      td.MessageOriginHiddenUser(:final senderName) => senderName,
      _ => '',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: '${context.t('forwarded_from')}\n'),
          TextSpan(text: name, style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
        style: TextStyle(fontSize: 13.5, color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class _ReplyHeader extends ConsumerWidget {
  const _ReplyHeader({required this.reply, required this.outgoing, required this.onTap});

  final td.MessageReplyToMessage reply;
  final bool outgoing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final replied = ref.watch(repliedMessageProvider((reply.chatId, reply.messageId))).value;
    final primary = Theme.of(context).colorScheme.primary;
    final name = replied != null ? account.senderName(replied.senderId) : '';
    final preview = reply.quote?.text.text ??
        (replied != null ? messagePreview(replied, account, s) : (reply.content != null ? s.t('message') : s.t('deleted_message')));
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(6, 6, 6, 0),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border(left: BorderSide(color: primary, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (name.isNotEmpty)
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: primary, fontWeight: FontWeight.w600, fontSize: 13.5)),
            Text(preview.replaceAll('\n', ' '), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
          ],
        ),
      ),
    );
  }
}

class _Reactions extends ConsumerWidget {
  const _Reactions({required this.message, required this.outgoing});

  final td.Message message;
  final bool outgoing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final primary = Theme.of(context).colorScheme.primary;
    final reactions = message.interactionInfo!.reactions!.reactions;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final reaction in reactions)
          if (reaction.type case td.ReactionTypeEmoji(:final emoji))
            GestureDetector(
              onTap: () => guard(context, () => account.toggleReaction(message, emoji)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: reaction.isChosen ? primary : primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '$emoji ${formatCount(reaction.totalCount)}',
                  style: TextStyle(fontSize: 13, color: reaction.isChosen ? Colors.white : primary, fontWeight: FontWeight.w600),
                ),
              ),
            ),
      ],
    );
  }
}
