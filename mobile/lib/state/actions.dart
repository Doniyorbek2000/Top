import 'dart:convert';
import 'dart:typed_data';

import 'package:tdlib_ex/td_api.dart' as td;

import '../core/tdlib/td_client.dart';
import 'telegram.dart';

td.FormattedText plainText(String text) => td.FormattedText(text: text, entities: const []);

/// Telegram's human-friendly markdown (**bold**, __italic__, ~~strike~~, ||spoiler||, `code`, ```pre```,
/// [text](url), [name](tg://user?id=1)) parsed synchronously by TDLib; falls back to plain text.
td.FormattedText formattedText(String text) {
  if (!_hasMarkup.hasMatch(text)) return plainText(text);
  try {
    final result = TdClient.executeStatic(td.ParseMarkdown(text: plainText(text)));
    final parsed = result?.toTdObject();
    if (parsed is td.FormattedText) return parsed;
  } on Object catch (_) {
    // Malformed markup or TDLib unavailable: send the text as typed.
  }
  return plainText(text);
}

final _hasMarkup = RegExp(r'\*\*|__|~~|\|\||`|\[[^\]]+\]\(');

const _noOptions = td.MessageSendOptions(
  suggestedPostInfo: null,
  disableNotification: false,
  fromBackground: false,
  protectContent: null,
  allowPaidBroadcast: null,
  paidMessageStarCount: 0,
  updateOrderOfInstalledStickerSets: false,
  schedulingState: null,
  effectId: 0,
  sendingId: 0,
  onlyPreview: false,
);

td.MessageSendOptions sendOptions({bool silent = false, int? scheduleAt}) => silent || scheduleAt != null
    ? _noOptions.copyWith(
        disableNotification: silent,
        schedulingState: scheduleAt == null ? null : td.MessageSchedulingStateSendAtDate(sendDate: scheduleAt, repeatPeriod: 0),
      )
    : _noOptions;

td.InputMessageReplyTo? replyTo(int? messageId) => messageId == null
    ? null
    : td.InputMessageReplyToMessage(messageId: messageId, quote: null, checklistTaskId: 0, pollOptionId: '');

/// Packs 0..31 amplitude samples into Telegram's 5-bit voice note waveform format (base64 bytes).
String encodeWaveform(List<int> samples) {
  final bytes = Uint8List((samples.length * 5 + 7) ~/ 8);
  for (var i = 0; i < samples.length; i++) {
    final value = samples[i].clamp(0, 31);
    final bitOffset = i * 5;
    final byteIndex = bitOffset >> 3;
    final shift = bitOffset & 7;
    bytes[byteIndex] |= (value << shift) & 0xFF;
    if (shift > 3 && byteIndex + 1 < bytes.length) bytes[byteIndex + 1] |= value >> (8 - shift);
  }
  return base64Encode(bytes);
}

/// Inverse of [encodeWaveform]; returns 0..31 samples.
List<int> decodeWaveform(String base64Data) {
  if (base64Data.isEmpty) return const [];
  final bytes = base64Decode(base64Data);
  final count = bytes.length * 8 ~/ 5;
  return List<int>.generate(count, (i) {
    final bitOffset = i * 5;
    final byteIndex = bitOffset >> 3;
    final shift = bitOffset & 7;
    var value = bytes[byteIndex] >> shift;
    if (shift > 3 && byteIndex + 1 < bytes.length) value |= bytes[byteIndex + 1] << (8 - shift);
    return value & 31;
  });
}

const muteForever = 0x7FFFFFFF;

extension ChatActions on TelegramAccount {
  Future<void> togglePinned(td.Chat chat, td.ChatList list) {
    final pinned = positionIn(chat, list)?.isPinned ?? false;
    return send<td.Ok>(td.ToggleChatIsPinned(chatList: list, chatId: chat.id, isPinned: !pinned));
  }

  Future<void> setArchived(td.Chat chat, bool archived) => send<td.Ok>(td.AddChatToList(
        chatId: chat.id,
        chatList: archived ? const td.ChatListArchive() : const td.ChatListMain(),
      ));

  bool isArchived(td.Chat chat) => positionIn(chat, const td.ChatListArchive()) != null;

  Future<void> setMuted(td.Chat chat, int muteForSeconds) => send<td.Ok>(td.SetChatNotificationSettings(
        chatId: chat.id,
        notificationSettings: chat.notificationSettings.copyWith(useDefaultMuteFor: false, muteFor: muteForSeconds),
      ));

  Future<void> markRead(td.Chat chat) async {
    final last = chat.lastMessage;
    if (last != null) {
      await send<td.Ok>(td.ViewMessages(chatId: chat.id, messageIds: [last.id], source: null, forceRead: true));
    }
    if (chat.isMarkedAsUnread) {
      await send<td.Ok>(td.ToggleChatIsMarkedAsUnread(chatId: chat.id, isMarkedAsUnread: false));
    }
    if (chat.unreadMentionCount > 0) await send<td.Ok>(td.ReadAllChatMentions(chatId: chat.id));
    if (chat.unreadReactionCount > 0) await send<td.Ok>(td.ReadAllChatReactions(chatId: chat.id));
  }

  Future<void> markUnread(td.Chat chat) =>
      send<td.Ok>(td.ToggleChatIsMarkedAsUnread(chatId: chat.id, isMarkedAsUnread: true));

  /// Deletes a private chat / leaves a group or channel and removes it from the list.
  Future<void> deleteChat(td.Chat chat, {bool forBoth = false}) async {
    if (privateUser(chat) != null || chat.type is td.ChatTypeSecret) {
      await send<td.Ok>(td.DeleteChatHistory(chatId: chat.id, removeFromChatList: true, revoke: forBoth));
      return;
    }
    if (isMember(chat)) await send<td.Ok>(td.LeaveChat(chatId: chat.id));
    await send<td.Ok>(td.DeleteChatHistory(chatId: chat.id, removeFromChatList: true, revoke: false));
  }

  Future<void> clearHistory(td.Chat chat, {bool forBoth = false}) =>
      send<td.Ok>(td.DeleteChatHistory(chatId: chat.id, removeFromChatList: false, revoke: forBoth));

  Future<td.Chat> openPrivateChat(int userId) => send<td.Chat>(td.CreatePrivateChat(userId: userId, force: false));

  Future<td.Chat> savedMessages() => openPrivateChat(myId);

  Future<void> sendTyping(int chatId, td.ChatAction? action) =>
      send<td.Ok>(td.SendChatAction(chatId: chatId, topicId: topicFor(chatId), businessConnectionId: null, action: action))
          .catchError((Object _) => const td.Ok());

  Future<void> saveDraft(int chatId, String text, {int? replyToMessageId}) => send<td.Ok>(td.SetChatDraftMessage(
        chatId: chatId,
        topicId: topicFor(chatId),
        draftMessage: text.trim().isEmpty
            ? null
            : td.DraftMessage(
                replyTo: replyTo(replyToMessageId),
                date: 0,
                content: td.DraftMessageContentText(text: plainText(text), linkPreviewOptions: null),
                effectId: 0,
                suggestedPostInfo: null,
              ),
      )).catchError((Object _) => const td.Ok());

  // ------------------------------------------------------------------ sending

  Future<td.Message> sendContent(int chatId, td.InputMessageContent content, {int? replyToId, bool silent = false, int? scheduleAt}) =>
      send<td.Message>(td.SendMessage(
        chatId: chatId,
        topicId: topicFor(chatId),
        replyTo: replyTo(replyToId),
        options: sendOptions(silent: silent, scheduleAt: scheduleAt),
        replyMarkup: null,
        inputMessageContent: content,
      ));

  Future<td.Message> sendText(int chatId, String text, {int? replyToId, bool silent = false, bool disablePreview = false, int? scheduleAt}) =>
      sendContent(
        chatId,
        td.InputMessageText(
          text: formattedText(text),
          linkPreviewOptions: disablePreview
              ? const td.LinkPreviewOptions(
                  isDisabled: true, url: '', forceSmallMedia: false, forceLargeMedia: false, showAboveText: false)
              : null,
          clearDraft: true,
        ),
        replyToId: replyToId,
        silent: silent,
        scheduleAt: scheduleAt,
      );

  Future<td.Message> sendPhoto(int chatId, String path, {String caption = '', int width = 0, int height = 0, int? replyToId}) =>
      sendContent(chatId, photoContent(path, caption: caption, width: width, height: height), replyToId: replyToId);

  Future<td.Message> sendVideo(int chatId, String path, {String caption = '', int? replyToId}) =>
      sendContent(chatId, videoContent(path, caption: caption), replyToId: replyToId);

  Future<td.Message> sendDocument(int chatId, String path, {String caption = '', int? replyToId}) => sendContent(
        chatId,
        td.InputMessageDocument(
          document: td.InputDocument(
            document: td.InputFileLocal(path: path),
            thumbnail: null,
            disableContentTypeDetection: false,
          ),
          caption: formattedText(caption),
        ),
        replyToId: replyToId,
      );

  Future<td.Message> sendVoice(int chatId, String path, {required int durationSeconds, required List<int> waveform, int? replyToId}) =>
      sendContent(
        chatId,
        td.InputMessageVoiceNote(
          voiceNote: td.InputVoiceNote(
            voiceNote: td.InputFileLocal(path: path),
            duration: durationSeconds,
            waveform: encodeWaveform(waveform),
          ),
          caption: null,
          selfDestructType: null,
        ),
        replyToId: replyToId,
      );

  Future<td.Message> sendLocation(int chatId, double latitude, double longitude) => sendContent(
        chatId,
        td.InputMessageLocation(
          location: td.Location(latitude: latitude, longitude: longitude, horizontalAccuracy: 0),
        ),
      );

  Future<td.Message> sendContactCard(int chatId, td.User user) => sendContent(
        chatId,
        td.InputMessageContact(
          contact: td.Contact(
            phoneNumber: user.phoneNumber,
            firstName: user.firstName,
            lastName: user.lastName,
            vcard: '',
            userId: user.id,
          ),
        ),
      );

  Future<td.Message> sendPoll(int chatId, String question, List<String> options, {bool anonymous = true, bool multiple = false}) =>
      sendContent(
        chatId,
        td.InputMessagePoll(
          question: plainText(question),
          options: [for (final option in options) td.InputPollOption(text: plainText(option), media: null)],
          description: null,
          media: null,
          isAnonymous: anonymous,
          allowsMultipleAnswers: multiple,
          allowsRevoting: true,
          membersOnly: false,
          countryCodes: const [],
          shuffleOptions: false,
          hideResultsUntilCloses: false,
          type: const td.InputPollTypeRegular(allowAddingOptions: false),
          openPeriod: 0,
          closeDate: 0,
          isClosed: null,
        ),
      );

  Future<void> resend(td.Message message) =>
      send<td.Messages>(td.ResendMessages(chatId: message.chatId, messageIds: [message.id], quote: null, paidMessageStarCount: 0));

  Future<void> editText(td.Message message, String text) {
    if (message.content is td.MessageText) {
      return send<td.Message>(td.EditMessageText(
        chatId: message.chatId,
        messageId: message.id,
        replyMarkup: null,
        inputMessageContent: td.InputMessageText(text: formattedText(text), linkPreviewOptions: null, clearDraft: false),
      ));
    }
    return send<td.Message>(td.EditMessageCaption(
      chatId: message.chatId,
      messageId: message.id,
      replyMarkup: null,
      caption: formattedText(text),
      showCaptionAboveMedia: false,
    ));
  }

  Future<void> deleteMessages(int chatId, List<int> ids, {required bool revoke}) =>
      send<td.Ok>(td.DeleteMessages(chatId: chatId, messageIds: ids, revoke: revoke));

  Future<void> forward(int fromChatId, List<int> ids, int toChatId, {bool hideSender = false}) =>
      send<td.Messages>(td.ForwardMessages(
        chatId: toChatId,
        topicId: topicFor(toChatId),
        fromChatId: fromChatId,
        messageIds: ids,
        options: _noOptions,
        sendCopy: hideSender,
        removeCaption: false,
      ));

  Future<void> toggleReaction(td.Message message, String emoji) async {
    final chosen = message.interactionInfo?.reactions?.reactions.where((r) => r.isChosen).map((r) => r.type) ?? const [];
    final already = chosen.any((t) => t is td.ReactionTypeEmoji && t.emoji == emoji);
    final type = td.ReactionTypeEmoji(emoji: emoji);
    if (already) {
      await send<td.Ok>(td.RemoveMessageReaction(chatId: message.chatId, messageId: message.id, reactionType: type));
    } else {
      await send<td.Ok>(td.AddMessageReaction(
        chatId: message.chatId,
        messageId: message.id,
        reactionType: type,
        isBig: false,
        updateRecentReactions: true,
      ));
    }
  }

  Future<void> setPinned(td.Message message, bool pinned) => pinned
      ? send<td.Ok>(td.PinChatMessage(chatId: message.chatId, messageId: message.id, disableNotification: false, onlyForSelf: false))
      : send<td.Ok>(td.UnpinChatMessage(chatId: message.chatId, messageId: message.id));

  Future<void> vote(td.Message message, List<int> optionIndexes) =>
      send<td.Ok>(td.SetPollAnswer(chatId: message.chatId, messageId: message.id, optionIds: optionIndexes));

  Future<String> messageLink(td.Message message) async {
    final link = await send<td.MessageLink>(td.GetMessageLink(
      chatId: message.chatId,
      messageId: message.id,
      mediaTimestamp: 0,
      checklistTaskId: 0,
      pollOptionId: '',
      forAlbum: false,
      inMessageThread: false,
    ));
    return link.link;
  }

  Future<td.Message?> pinnedMessage(int chatId) async {
    try {
      return await send<td.Message>(td.GetChatPinnedMessage(chatId: chatId));
    } on TdException {
      return null;
    }
  }

  // ------------------------------------------------------------------ Telegram AI (TDLib 1.8.68)

  Future<String> translate(String text, String toLanguage) async =>
      (await send<td.FormattedText>(td.TranslateText(text: plainText(text), toLanguageCode: toLanguage, tone: ''))).text;

  Future<String> translateMessage(td.Message message, String toLanguage) async => (await send<td.FormattedText>(
        td.TranslateMessageText(chatId: message.chatId, messageId: message.id, toLanguageCode: toLanguage, tone: ''),
      ))
          .text;

  Future<String> summarize(td.Message message, String toLanguage) async => (await send<td.FormattedText>(
        td.SummarizeMessage(chatId: message.chatId, messageId: message.id, translateToLanguageCode: toLanguage, tone: ''),
      ))
          .text;

  Future<String> composeWithAi(String text, {String styleName = '', String translateTo = '', bool addEmojis = false}) async =>
      (await send<td.FormattedText>(td.ComposeTextWithAi(
        text: plainText(text),
        translateToLanguageCode: translateTo,
        styleName: styleName,
        addEmojis: addEmojis,
      )))
          .text;

  Future<String> fixWithAi(String text) async =>
      (await send<td.FixedText>(td.FixTextWithAi(text: plainText(text)))).text.text;

  Future<void> recognizeSpeech(td.Message message) =>
      send<td.Ok>(td.RecognizeSpeech(chatId: message.chatId, messageId: message.id));
}

/// Bot interactions: inline/reply keyboard buttons, Mini Apps and Telegram Stars payments.
extension BotActions on TelegramAccount {
  /// The bot behind a message: the inline bot it was sent via, otherwise the sending user.
  int botUserIdOf(td.Message message) {
    if (message.viaBotUserId != 0) return message.viaBotUserId;
    final sender = message.senderId;
    return sender is td.MessageSenderUser ? sender.userId : 0;
  }

  Future<td.CallbackQueryAnswer> callbackAnswer(td.Message message, td.CallbackQueryPayload payload) =>
      send<td.CallbackQueryAnswer>(td.GetCallbackQueryAnswer(chatId: message.chatId, messageId: message.id, payload: payload));

  Future<td.LoginUrlInfo> loginUrlInfo(td.Message message, int buttonId) =>
      send<td.LoginUrlInfo>(td.GetLoginUrlInfo(chatId: message.chatId, messageId: message.id, buttonId: buttonId));

  Future<String> loginUrl(td.Message message, int buttonId, {required bool allowWriteAccess}) async =>
      (await send<td.HttpUrl>(td.GetLoginUrl(
        chatId: message.chatId,
        messageId: message.id,
        buttonId: buttonId,
        allowWriteAccess: allowWriteAccess,
      )))
          .url;

  /// Mini App launched from an inline button or the bot menu; must be closed with [closeWebApp].
  Future<td.WebAppInfo> openWebApp(int chatId, int botUserId, String url, td.ThemeParameters theme, {int? replyToId}) =>
      send<td.WebAppInfo>(td.OpenWebApp(
        chatId: chatId,
        botUserId: botUserId,
        url: url,
        topicId: null,
        replyTo: replyTo(replyToId),
        parameters: webAppParameters(theme),
      ));

  /// Mini App launched from a reply keyboard button (can send data back with [sendWebAppData]).
  Future<String> webAppUrl(int botUserId, String url, td.ThemeParameters theme) async =>
      (await send<td.WebAppUrl>(td.GetWebAppUrl(botUserId: botUserId, url: url, parameters: webAppParameters(theme)))).url;

  Future<void> closeWebApp(int launchId) =>
      send<td.Ok>(td.CloseWebApp(webAppLaunchId: launchId)).catchError((Object _) => const td.Ok());

  Future<void> sendWebAppData(int botUserId, String buttonText, String data) =>
      send<td.Ok>(td.SendWebAppData(botUserId: botUserId, buttonText: buttonText, data: data));

  Future<td.PaymentForm> paymentForm(td.Message message, td.ThemeParameters theme) => send<td.PaymentForm>(td.GetPaymentForm(
        inputInvoice: td.InputInvoiceMessage(chatId: message.chatId, messageId: message.id),
        theme: theme,
      ));

  /// Pays an invoice in Telegram Stars (no card data involved; Telegram debits the user's Star balance).
  Future<td.PaymentResult> payWithStars(td.Message message, int paymentFormId) => send<td.PaymentResult>(td.SendPaymentForm(
        inputInvoice: td.InputInvoiceMessage(chatId: message.chatId, messageId: message.id),
        paymentFormId: paymentFormId,
        orderInfoId: '',
        shippingOptionId: '',
        credentials: null,
        tipAmount: 0,
      ));

  Future<void> startBot(int botUserId, int chatId) =>
      send<td.Message>(td.SendBotStartMessage(botUserId: botUserId, chatId: chatId, parameter: ''));
}

td.WebAppOpenParameters webAppParameters(td.ThemeParameters theme) =>
    td.WebAppOpenParameters(theme: theme, applicationName: 'Sado', mode: const td.WebAppOpenModeFullSize());

extension ForumActions on TelegramAccount {
  Future<td.ForumTopics> forumTopics(int chatId, {int offsetDate = 0, int offsetMessageId = 0, int offsetTopicId = 0, String query = ''}) =>
      send<td.ForumTopics>(td.GetForumTopics(
        chatId: chatId,
        query: query,
        offsetDate: offsetDate,
        offsetMessageId: offsetMessageId,
        offsetForumTopicId: offsetTopicId,
        limit: 50,
      ));
}

extension ScheduledActions on TelegramAccount {
  Future<List<td.Message>> scheduledMessages(int chatId) async =>
      ((await send<td.Messages>(td.GetChatScheduledMessages(chatId: chatId))).messages ?? const <td.Message>[]).toList();

  /// Sends a scheduled message right away (scheduling state null = now).
  Future<void> sendScheduledNow(td.Message message) =>
      send<td.Ok>(td.EditMessageSchedulingState(chatId: message.chatId, messageId: message.id, schedulingState: null));

  Future<void> reschedule(td.Message message, int sendAt) => send<td.Ok>(td.EditMessageSchedulingState(
        chatId: message.chatId,
        messageId: message.id,
        schedulingState: td.MessageSchedulingStateSendAtDate(sendDate: sendAt, repeatPeriod: 0),
      ));
}

/// Composer helpers: mentions, inline bots, stickers and GIFs.
extension ComposeActions on TelegramAccount {
  Future<List<td.ChatMember>> mentionCandidates(int chatId, String query) async =>
      (await send<td.ChatMembers>(td.SearchChatMembers(
        chatId: chatId,
        query: query,
        limit: 20,
        filter: td.ChatMembersFilterMention(topicId: topicFor(chatId)),
      )))
          .members;

  /// Resolves "@username" to an inline bot, or null when it is not one.
  Future<td.User?> inlineBot(String username) async {
    try {
      final chat = await send<td.Chat>(td.SearchPublicChat(username: username));
      final user = privateUser(chat) ?? (chat.type is td.ChatTypePrivate ? await getUser((chat.type as td.ChatTypePrivate).userId) : null);
      final type = user?.type;
      return type is td.UserTypeBot && type.isInline ? user : null;
    } on TdException {
      return null;
    }
  }

  Future<td.InlineQueryResults> inlineResults(int botUserId, int chatId, String query, {String offset = ''}) =>
      send<td.InlineQueryResults>(td.GetInlineQueryResults(
        botUserId: botUserId,
        chatId: chatId,
        userLocation: null,
        query: query,
        offset: offset,
      ));

  Future<td.Message> sendInlineResult(int chatId, int queryId, String resultId, {int? replyToId}) =>
      send<td.Message>(td.SendInlineQueryResultMessage(
        chatId: chatId,
        topicId: topicFor(chatId),
        replyTo: replyTo(replyToId),
        options: sendOptions(),
        queryId: queryId,
        resultId: resultId,
        hideViaBot: false,
      ));

  Future<List<td.StickerSetInfo>> installedStickerSets() async =>
      (await send<td.StickerSets>(const td.GetInstalledStickerSets(stickerType: td.StickerTypeRegular()))).sets;

  Future<td.StickerSet> stickerSet(int setId) => send<td.StickerSet>(td.GetStickerSet(setId: setId));

  Future<List<td.Sticker>> recentStickers() async =>
      (await send<td.Stickers>(const td.GetRecentStickers(isAttached: false))).stickers;

  Future<List<td.Sticker>> favoriteStickers() async => (await send<td.Stickers>(const td.GetFavoriteStickers())).stickers;

  Future<List<td.Animation>> savedAnimations() async => (await send<td.Animations>(const td.GetSavedAnimations())).animations;

  Future<td.Message> sendSticker(int chatId, td.Sticker sticker, {int? replyToId}) => sendContent(
        chatId,
        td.InputMessageSticker(
          sticker: td.InputSticker(sticker: td.InputFileId(id: sticker.sticker.id), thumbnail: null, width: sticker.width, height: sticker.height),
          emoji: sticker.emoji,
        ),
        replyToId: replyToId,
      );

  Future<td.Message> sendAnimation(int chatId, td.Animation animation, {int? replyToId}) => sendContent(
        chatId,
        td.InputMessageAnimation(
          animation: td.InputAnimation(
            animation: td.InputFileId(id: animation.animation.id),
            thumbnail: null,
            addedStickerFileIds: const [],
            duration: animation.duration,
            width: animation.width,
            height: animation.height,
          ),
          caption: null,
          showCaptionAboveMedia: false,
          hasSpoiler: false,
        ),
        replyToId: replyToId,
      );
}

/// Inverse of [formattedText] for editing: turns entities back into the markdown the composer understands.
String toMarkdown(td.FormattedText text) {
  final entities = [...text.entities]..sort((a, b) => a.offset.compareTo(b.offset));
  final buffer = StringBuffer();
  var cursor = 0;
  for (final entity in entities) {
    final start = entity.offset.clamp(0, text.text.length);
    final end = (entity.offset + entity.length).clamp(start, text.text.length);
    if (start < cursor) continue; // nested entities keep only the outer markup
    final (left, right) = switch (entity.type) {
      td.TextEntityTypeBold() => ('**', '**'),
      td.TextEntityTypeItalic() => ('__', '__'),
      td.TextEntityTypeStrikethrough() => ('~~', '~~'),
      td.TextEntityTypeSpoiler() => ('||', '||'),
      td.TextEntityTypeCode() => ('`', '`'),
      td.TextEntityTypePre() || td.TextEntityTypePreCode() => ('```', '```'),
      td.TextEntityTypeTextUrl(:final url) => ('[', ']($url)'),
      td.TextEntityTypeMentionName(:final userId) => ('[', '](tg://user?id=$userId)'),
      _ => ('', ''),
    };
    if (left.isEmpty) continue;
    buffer
      ..write(text.text.substring(cursor, start))
      ..write(left)
      ..write(text.text.substring(start, end))
      ..write(right);
    cursor = end;
  }
  buffer.write(text.text.substring(cursor));
  return buffer.toString();
}

td.InputMessageContent photoContent(String path, {String caption = '', int width = 0, int height = 0}) => td.InputMessagePhoto(
      photo: td.InputPhoto(
        photo: td.InputFileLocal(path: path),
        thumbnail: null,
        video: null,
        addedStickerFileIds: const [],
        width: width,
        height: height,
      ),
      caption: formattedText(caption),
      showCaptionAboveMedia: false,
      selfDestructType: null,
      hasSpoiler: false,
    );

td.InputMessageContent videoContent(String path, {String caption = ''}) => td.InputMessageVideo(
      video: td.InputVideo(
        video: td.InputFileLocal(path: path),
        thumbnail: null,
        cover: null,
        startTimestamp: 0,
        addedStickerFileIds: const [],
        duration: 0,
        width: 0,
        height: 0,
        supportsStreaming: true,
      ),
      caption: formattedText(caption),
      showCaptionAboveMedia: false,
      selfDestructType: null,
      hasSpoiler: false,
    );

/// Albums, the downloads list and saving media.
extension MediaActions on TelegramAccount {
  /// Sends 2..10 photos/videos as one album (Telegram groups them by media_album_id).
  Future<void> sendAlbum(int chatId, List<td.InputMessageContent> contents, {int? replyToId}) async {
    if (contents.length == 1) {
      await sendContent(chatId, contents.first, replyToId: replyToId);
      return;
    }
    await send<td.Messages>(td.SendMessageAlbum(
      chatId: chatId,
      topicId: topicFor(chatId),
      replyTo: replyTo(replyToId),
      options: sendOptions(),
      inputMessageContents: contents,
    ));
  }

  /// Downloads through TDLib's download list so the file shows up in the Downloads screen.
  Future<void> addToDownloads(td.Message message, int fileId, {int priority = 16}) async {
    final file = await send<td.File>(
      td.AddFileToDownloads(fileId: fileId, chatId: message.chatId, messageId: message.id, priority: priority),
    );
    files[file.id] = file;
  }

  Future<td.FoundFileDownloads> fileDownloads({String offset = ''}) => send<td.FoundFileDownloads>(
        td.SearchFileDownloads(query: '', onlyActive: false, onlyCompleted: false, offset: offset, limit: 100),
      );

  Future<void> setDownloadPaused(int fileId, bool paused) =>
      send<td.Ok>(td.ToggleDownloadIsPaused(fileId: fileId, isPaused: paused));

  Future<void> removeDownload(int fileId, {bool deleteFile = false}) =>
      send<td.Ok>(td.RemoveFileFromDownloads(fileId: fileId, deleteFromCache: deleteFile));

  Future<void> clearDownloads({bool deleteFiles = false}) =>
      send<td.Ok>(td.RemoveAllFilesFromDownloads(onlyActive: false, onlyCompleted: false, deleteFromCache: deleteFiles));
}

/// The downloadable media file of a message (photo at full size, video, GIF, document, audio...).
td.File? mediaFileOf(td.Message message) => switch (message.content) {
      td.MessagePhoto(:final photo) => photo.sizes.isEmpty ? null : (photo.sizes.toList()..sort((a, b) => a.width.compareTo(b.width))).last.photo,
      td.MessageVideo(:final video) => video.video,
      td.MessageAnimation(:final animation) => animation.animation,
      td.MessageVideoNote(:final videoNote) => videoNote.video,
      td.MessageDocument(:final document) => document.document,
      td.MessageAudio(:final audio) => audio.audio,
      td.MessageVoiceNote(:final voiceNote) => voiceNote.voice,
      _ => null,
    };

/// Proxy, storage, two-step verification and secret chats.
extension SettingsActions on TelegramAccount {
  Future<List<td.AddedProxy>> proxies() async => (await send<td.AddedProxies>(const td.GetProxies())).proxies;

  Future<td.AddedProxy> addProxy(td.Proxy proxy, {bool enable = true}) =>
      send<td.AddedProxy>(td.AddProxy(proxy: proxy, enable: enable, comment: ''));

  Future<void> enableProxy(int id) => send<td.Ok>(td.EnableProxy(proxyId: id));

  Future<void> disableProxy() => send<td.Ok>(const td.DisableProxy());

  Future<void> removeProxy(int id) => send<td.Ok>(td.RemoveProxy(proxyId: id));

  /// Round-trip time in milliseconds, or null when the proxy does not answer.
  Future<int?> pingProxy(td.Proxy proxy) async {
    try {
      final result = await send<td.Seconds>(td.PingProxy(proxy: proxy));
      return (result.seconds * 1000).round();
    } on TdException {
      return null;
    }
  }

  Future<td.StorageStatisticsFast> storageStats() => send<td.StorageStatisticsFast>(const td.GetStorageStatisticsFast());

  /// Deletes cached files; [ttl] keeps files used within that many seconds (0 = delete everything).
  Future<void> clearCache({int ttl = 0}) => send<td.StorageStatistics>(td.OptimizeStorage(
        size: 0,
        ttl: ttl,
        count: 0,
        immunityDelay: 0,
        fileTypes: const [],
        chatIds: const [],
        excludeChatIds: const [],
        returnDeletedFileStatistics: false,
        chatLimit: 0,
      ));

  Future<td.PasswordState> passwordState() => send<td.PasswordState>(const td.GetPasswordState());

  Future<td.PasswordState> setPassword({
    required String oldPassword,
    required String newPassword,
    String hint = '',
    String recoveryEmail = '',
  }) =>
      send<td.PasswordState>(td.SetPassword(
        oldPassword: oldPassword,
        newPassword: newPassword,
        newHint: hint,
        setRecoveryEmailAddress: recoveryEmail.isNotEmpty,
        newRecoveryEmailAddress: recoveryEmail,
      ));

  Future<td.PasswordState> setRecoveryEmail(String password, String email) =>
      send<td.PasswordState>(td.SetRecoveryEmailAddress(password: password, newRecoveryEmailAddress: email));

  Future<td.PasswordState> confirmRecoveryEmail(String code) =>
      send<td.PasswordState>(td.CheckRecoveryEmailAddressCode(code: code));

  Future<td.Chat> createSecretChat(int userId) => send<td.Chat>(td.CreateNewSecretChat(userId: userId));

  Future<void> closeSecretChat(int secretChatId) => send<td.Ok>(td.CloseSecretChat(secretChatId: secretChatId));
}

/// Parses t.me/proxy, t.me/socks and tg://proxy|socks links into a proxy.
td.Proxy? parseProxyLink(String link) {
  final uri = Uri.tryParse(link.trim());
  if (uri == null) return null;
  final kind = uri.scheme == 'tg' ? uri.host : (uri.pathSegments.isEmpty ? '' : uri.pathSegments.first);
  final params = uri.queryParameters;
  final server = params['server'] ?? '';
  final port = int.tryParse(params['port'] ?? '') ?? 0;
  if (server.isEmpty || port <= 0 || port > 65535) return null;
  return switch (kind) {
    'proxy' when (params['secret'] ?? '').isNotEmpty =>
      td.Proxy(server: server, port: port, type: td.ProxyTypeMtproto(secret: params['secret']!)),
    'socks' => td.Proxy(server: server, port: port, type: td.ProxyTypeSocks5(username: params['user'] ?? '', password: params['pass'] ?? '')),
    _ => null,
  };
}

/// Group and channel administration.
extension AdminActions on TelegramAccount {
  /// Members of a group/channel; [filter] is 'recent', 'admins', 'restricted', 'banned' or 'bots'.
  Future<List<td.ChatMember>> members(td.Chat chat, {String filter = 'recent', String query = '', int offset = 0}) async {
    final supergroup = supergroupOf(chat);
    if (supergroup == null) {
      final info = await send<td.BasicGroupFullInfo>(td.GetBasicGroupFullInfo(basicGroupId: basicGroupOf(chat)!.id));
      return info.members;
    }
    final td.SupergroupMembersFilter supergroupFilter = switch (filter) {
      'admins' => const td.SupergroupMembersFilterAdministrators(),
      'restricted' => td.SupergroupMembersFilterRestricted(query: query),
      'banned' => td.SupergroupMembersFilterBanned(query: query),
      'bots' => const td.SupergroupMembersFilterBots(),
      _ => query.isEmpty ? const td.SupergroupMembersFilterRecent() : td.SupergroupMembersFilterSearch(query: query),
    };
    return (await send<td.ChatMembers>(
      td.GetSupergroupMembers(supergroupId: supergroup.id, filter: supergroupFilter, offset: offset, limit: 200),
    ))
        .members;
  }

  Future<td.ChatMember> member(int chatId, int userId) =>
      send<td.ChatMember>(td.GetChatMember(chatId: chatId, memberId: td.MessageSenderUser(userId: userId)));

  Future<void> setMemberStatus(int chatId, int userId, td.ChatMemberStatus status) =>
      send<td.Ok>(td.SetChatMemberStatus(chatId: chatId, memberId: td.MessageSenderUser(userId: userId), status: status));

  Future<void> banMember(int chatId, int userId, {bool deleteMessages = false}) => send<td.Ok>(td.BanChatMember(
        chatId: chatId,
        memberId: td.MessageSenderUser(userId: userId),
        bannedUntilDate: 0,
        revokeMessages: deleteMessages,
      ));

  Future<void> setDefaultPermissions(int chatId, td.ChatPermissions permissions) =>
      send<td.Ok>(td.SetChatPermissions(chatId: chatId, permissions: permissions));

  Future<void> setSlowMode(int chatId, int seconds) => send<td.Ok>(td.SetChatSlowModeDelay(chatId: chatId, slowModeDelay: seconds));

  Future<void> setAutoDelete(int chatId, int seconds) =>
      send<td.Ok>(td.SetChatMessageAutoDeleteTime(chatId: chatId, messageAutoDeleteTime: seconds));

  Future<td.SupergroupFullInfo> supergroupInfo(int supergroupId) =>
      send<td.SupergroupFullInfo>(td.GetSupergroupFullInfo(supergroupId: supergroupId));

  Future<List<td.ChatInviteLink>> inviteLinks(int chatId, {bool revoked = false}) async => (await send<td.ChatInviteLinks>(td.GetChatInviteLinks(
        chatId: chatId,
        creatorUserId: myId,
        isRevoked: revoked,
        offsetDate: 0,
        offsetInviteLink: '',
        limit: 100,
      )))
          .inviteLinks;

  Future<td.ChatInviteLink> createInviteLink(int chatId, {String name = '', int expiresAt = 0, int memberLimit = 0, bool joinRequest = false}) =>
      send<td.ChatInviteLink>(td.CreateChatInviteLink(
        chatId: chatId,
        name: name,
        expirationDate: expiresAt,
        memberLimit: joinRequest ? 0 : memberLimit,
        createsJoinRequest: joinRequest,
      ));

  Future<void> revokeInviteLink(int chatId, String link) =>
      send<td.ChatInviteLinks>(td.RevokeChatInviteLink(chatId: chatId, inviteLink: link));

  Future<void> deleteRevokedInviteLink(int chatId, String link) =>
      send<td.Ok>(td.DeleteRevokedChatInviteLink(chatId: chatId, inviteLink: link));

  Future<td.ChatJoinRequests> joinRequests(int chatId) => send<td.ChatJoinRequests>(
        td.GetChatJoinRequests(chatId: chatId, inviteLink: '', query: '', offsetRequest: null, limit: 100),
      );

  Future<void> processJoinRequest(int chatId, int userId, {required bool approve}) =>
      send<td.Ok>(td.ProcessChatJoinRequest(chatId: chatId, userId: userId, approve: approve));
}

/// Live location and stories.
extension LiveActions on TelegramAccount {
  Future<td.Message> sendLiveLocation(int chatId, double latitude, double longitude, {required int periodSeconds}) => sendContent(
        chatId,
        td.InputMessageLiveLocation(
          location: td.LiveLocation(
            location: td.Location(latitude: latitude, longitude: longitude, horizontalAccuracy: 0),
            livePeriod: periodSeconds,
            heading: 0,
            proximityAlertRadius: 0,
          ),
        ),
      );

  /// Updates a live location; [latitude] null stops sharing.
  Future<void> updateLiveLocation(int chatId, int messageId, {double? latitude, double? longitude}) => send<td.Message>(td.EditMessageLiveLocation(
        chatId: chatId,
        messageId: messageId,
        replyMarkup: null,
        location: latitude == null || longitude == null
            ? null
            : td.LiveLocation(
                location: td.Location(latitude: latitude, longitude: longitude, horizontalAccuracy: 0),
                livePeriod: 0,
                heading: 0,
                proximityAlertRadius: 0,
              ),
      ));

  Future<td.CanPostStoryResult> canPostStory() => send<td.CanPostStoryResult>(td.CanPostStory(chatId: myId));

  /// Posts a photo or video story to the user's own profile for [activeSeconds] (6/12/24/48 h).
  Future<td.Story> postStory(String path, {required bool isVideo, String caption = '', bool contactsOnly = false, int activeSeconds = 86400}) =>
      send<td.Story>(td.PostStory(
        chatId: myId,
        content: isVideo
            ? td.InputStoryContentVideo(
                video: td.InputFileLocal(path: path),
                addedStickerFileIds: const [],
                duration: 0,
                coverFrameTimestamp: 0,
                isAnimation: false,
              )
            : td.InputStoryContentPhoto(photo: td.InputFileLocal(path: path), addedStickerFileIds: const []),
        areas: null,
        caption: formattedText(caption),
        privacySettings: contactsOnly
            ? const td.StoryPrivacySettingsContacts(exceptUserIds: [])
            : const td.StoryPrivacySettingsEveryone(exceptUserIds: []),
        albumIds: const [],
        activePeriod: activeSeconds,
        fromStoryFullId: null,
        isPostedToChatPage: true,
        protectContent: false,
      ));

  Future<void> reactToStory(int posterChatId, int storyId, String? emoji) => send<td.Ok>(td.SetStoryReaction(
        storyPosterChatId: posterChatId,
        storyId: storyId,
        reactionType: emoji == null ? null : td.ReactionTypeEmoji(emoji: emoji),
        updateRecentReactions: true,
      ));

  Future<td.Message> replyToStory(int posterChatId, int storyId, String text) => send<td.Message>(td.SendMessage(
        chatId: posterChatId,
        topicId: null,
        replyTo: td.InputMessageReplyToStory(storyPosterChatId: posterChatId, storyId: storyId),
        options: sendOptions(),
        replyMarkup: null,
        inputMessageContent: td.InputMessageText(text: formattedText(text), linkPreviewOptions: null, clearDraft: false),
      ));
}
