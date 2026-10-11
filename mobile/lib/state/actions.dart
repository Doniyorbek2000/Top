import 'dart:convert';
import 'dart:typed_data';

import 'package:tdlib_ex/td_api.dart' as td;

import '../core/tdlib/td_client.dart';
import 'telegram.dart';

td.FormattedText plainText(String text) => td.FormattedText(text: text, entities: const []);

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
          text: plainText(text),
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
      sendContent(
        chatId,
        td.InputMessagePhoto(
          photo: td.InputPhoto(
            photo: td.InputFileLocal(path: path),
            thumbnail: null,
            video: null,
            addedStickerFileIds: const [],
            width: width,
            height: height,
          ),
          caption: plainText(caption),
          showCaptionAboveMedia: false,
          selfDestructType: null,
          hasSpoiler: false,
        ),
        replyToId: replyToId,
      );

  Future<td.Message> sendVideo(int chatId, String path, {String caption = '', int? replyToId}) => sendContent(
        chatId,
        td.InputMessageVideo(
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
          caption: plainText(caption),
          showCaptionAboveMedia: false,
          selfDestructType: null,
          hasSpoiler: false,
        ),
        replyToId: replyToId,
      );

  Future<td.Message> sendDocument(int chatId, String path, {String caption = '', int? replyToId}) => sendContent(
        chatId,
        td.InputMessageDocument(
          document: td.InputDocument(
            document: td.InputFileLocal(path: path),
            thumbnail: null,
            disableContentTypeDetection: false,
          ),
          caption: plainText(caption),
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
        inputMessageContent: td.InputMessageText(text: plainText(text), linkPreviewOptions: null, clearDraft: false),
      ));
    }
    return send<td.Message>(td.EditMessageCaption(
      chatId: message.chatId,
      messageId: message.id,
      replyMarkup: null,
      caption: plainText(text),
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
