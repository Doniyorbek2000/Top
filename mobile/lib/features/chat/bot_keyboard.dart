import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../webapp/web_app_screen.dart';
import 'forward_picker.dart';
import 'message_content.dart';

/// Called when a button wants text placed in the composer ("@bot query" for switch-inline buttons).
typedef InsertText = void Function(String text);

Future<void> _openUrl(BuildContext context, String url, {bool ask = true}) async {
  final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
  if (uri == null) return;
  if (ask && !(uri.host == 't.me' || uri.host == 'telegram.me' || uri.scheme == 'tg')) {
    final ok = await confirm(context, title: context.t('open_link'), message: url);
    if (!ok) return;
  }
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Color? _styleColor(BuildContext context, td.ButtonStyle? style) => switch (style) {
      td.ButtonStylePrimary() => Theme.of(context).colorScheme.primary,
      td.ButtonStyleDanger() => Theme.of(context).colorScheme.error,
      td.ButtonStyleSuccess() => Colors.green.shade600,
      _ => null,
    };

/// Inline keyboard attached under a bot message.
class InlineKeyboardView extends ConsumerWidget {
  const InlineKeyboardView({super.key, required this.message, required this.rows, required this.maxWidth, this.onInsertText});

  final td.Message message;
  final List<List<td.InlineKeyboardButton>> rows;
  final double maxWidth;
  final InsertText? onInsertText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows)
            Row(
              children: [
                for (final button in row)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: _InlineButton(message: message, button: button, onInsertText: onInsertText),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _InlineButton extends ConsumerStatefulWidget {
  const _InlineButton({required this.message, required this.button, this.onInsertText});

  final td.Message message;
  final td.InlineKeyboardButton button;
  final InsertText? onInsertText;

  @override
  ConsumerState<_InlineButton> createState() => _InlineButtonState();
}

class _InlineButtonState extends ConsumerState<_InlineButton> {
  bool _busy = false;

  IconData? get _icon => switch (widget.button.type) {
        td.InlineKeyboardButtonTypeUrl() || td.InlineKeyboardButtonTypeLoginUrl() => Icons.north_east_rounded,
        td.InlineKeyboardButtonTypeWebApp() => Icons.apps_rounded,
        td.InlineKeyboardButtonTypeSwitchInline() => Icons.reply_rounded,
        td.InlineKeyboardButtonTypeCopyText() => Icons.copy_rounded,
        td.InlineKeyboardButtonTypeBuy() => Icons.star_rounded,
        _ => null,
      };

  Future<void> _press() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _handle();
    } on TdException catch (error) {
      if (mounted) showToast(context, errorTextFromCode(context, error.message));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handle() async {
    final account = ref.read(accountProvider);
    final message = widget.message;
    final botId = account.botUserIdOf(message);
    switch (widget.button.type) {
      case td.InlineKeyboardButtonTypeUrl(:final url):
        await _openUrl(context, url);
      case td.InlineKeyboardButtonTypeLoginUrl(:final url, :final id):
        await _login(url, id);
      case td.InlineKeyboardButtonTypeWebApp(:final url):
        await openInlineWebApp(context, ref, chatId: message.chatId, botUserId: botId, url: url);
      case td.InlineKeyboardButtonTypeCallback(:final data):
        await _showAnswer(await account.callbackAnswer(message, td.CallbackQueryPayloadData(data: data)));
      case td.InlineKeyboardButtonTypeCallbackWithPassword(:final data):
        final password = await _askPassword();
        if (password == null) return;
        await _showAnswer(await account.callbackAnswer(message, td.CallbackQueryPayloadDataWithPassword(password: password, data: data)));
      case td.InlineKeyboardButtonTypeCallbackGame():
        final content = message.content;
        if (content is td.MessageGame) {
          await _showAnswer(await account.callbackAnswer(message, td.CallbackQueryPayloadGame(gameShortName: content.game.shortName)));
        }
      case td.InlineKeyboardButtonTypeSwitchInline(:final query, :final targetChat):
        await _switchInline(botId, query, targetChat);
      case td.InlineKeyboardButtonTypeUser(:final userId):
        final chat = await account.openPrivateChat(userId);
        if (mounted) openChatFromContent(context, chat.id);
      case td.InlineKeyboardButtonTypeCopyText(:final text):
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) showToast(context, context.t('copied'));
      case td.InlineKeyboardButtonTypeBuy():
        await payInvoice(context, ref, message);
      default:
        break;
    }
  }

  Future<void> _login(String fallbackUrl, int buttonId) async {
    final account = ref.read(accountProvider);
    final info = await account.loginUrlInfo(widget.message, buttonId);
    if (!mounted) return;
    switch (info) {
      case td.LoginUrlInfoOpen(:final url, :final skipConfirmation):
        await _openUrl(context, url, ask: !skipConfirmation);
      case td.LoginUrlInfoRequestConfirmation(:final domain, :final botUserId, :final requestWriteAccess):
        var allowWrite = requestWriteAccess;
        final s = context.s;
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(s.t('login_url_title')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.t('login_url_text', {'domain': domain})),
                  if (requestWriteAccess)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: allowWrite,
                      onChanged: (v) => setDialogState(() => allowWrite = v ?? false),
                      title: Text(s.t('login_url_write', {'bot': account.userName(botUserId)})),
                    ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('cancel'))),
                TextButton(onPressed: () => Navigator.pop(context, true), child: Text(s.t('login_url_confirm'))),
              ],
            ),
          ),
        );
        if (!mounted) return;
        if (ok == true) {
          final url = await account.loginUrl(widget.message, buttonId, allowWriteAccess: allowWrite);
          if (mounted) await _openUrl(context, url, ask: false);
        } else if (ok == false) {
          await _openUrl(context, fallbackUrl);
        }
      default:
        break;
    }
  }

  Future<String?> _askPassword() async {
    final controller = TextEditingController();
    final s = context.s;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('enter_password')),
        content: TextField(controller: controller, obscureText: true, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(s.t('ok'))),
        ],
      ),
    );
    controller.dispose();
    return result == null || result.isEmpty ? null : result;
  }

  Future<void> _showAnswer(td.CallbackQueryAnswer answer) async {
    if (!mounted) return;
    if (answer.url.isNotEmpty) {
      await _openUrl(context, answer.url, ask: false);
      return;
    }
    if (answer.text.isEmpty) return;
    if (answer.showAlert) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(answer.text),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('ok')))],
        ),
      );
    } else {
      showToast(context, answer.text);
    }
  }

  Future<void> _switchInline(int botId, String query, td.TargetChat targetChat) async {
    final account = ref.read(accountProvider);
    final username = account.users[botId]?.usernames?.activeUsernames.firstOrNull;
    if (username == null) return;
    final text = '@$username $query';
    if (targetChat is td.TargetChatCurrent) {
      widget.onInsertText?.call(text);
      return;
    }
    final target = await Navigator.of(context).push<int>(MaterialPageRoute(builder: (_) => const ForwardPickerScreen()));
    if (target == null || !mounted) return;
    await account.saveDraft(target, text);
    if (mounted) openChatFromContent(context, target);
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.button.type is td.InlineKeyboardButtonTypeDisabled;
    final accent = _styleColor(context, widget.button.style);
    final icon = _icon;
    return Material(
      color: accent?.withValues(alpha: 0.85) ?? Colors.black.withValues(alpha: 0.22),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: disabled ? null : _press,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Stack(
            children: [
              Container(
                width: double.infinity,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                child: _busy
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(
                        widget.button.text,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: disabled ? Colors.white54 : Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                      ),
              ),
              if (icon != null) Positioned(top: 4, right: 5, child: Icon(icon, size: 11, color: Colors.white.withValues(alpha: 0.9))),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pays an invoice. Telegram Stars invoices are paid in-app; card invoices need the payment
/// provider's own form, which is opened in the official flow via the invoice link.
Future<void> payInvoice(BuildContext context, WidgetRef ref, td.Message message) async {
  final account = ref.read(accountProvider);
  final s = context.s;
  final form = await guard(context, () => account.paymentForm(message, themeParametersOf(context)));
  if (form == null || !context.mounted) return;
  switch (form.type) {
    case td.PaymentFormTypeStars(:final starCount):
      final ok = await confirm(
        context,
        title: form.productInfo.title,
        message: s.t('stars_pay_confirm', {'count': '$starCount', 'bot': account.userName(form.sellerBotUserId)}),
      );
      if (!ok || !context.mounted) return;
      final result = await guard(context, () => account.payWithStars(message, form.id));
      if (result == null || !context.mounted) return;
      if (result.verificationUrl.isNotEmpty) {
        await launchUrl(Uri.parse(result.verificationUrl), mode: LaunchMode.externalApplication);
      } else if (result.success) {
        showToast(context, s.t('payment_done'));
      }
    default:
      showToast(context, s.t('payment_card_unsupported'));
  }
}

/// Reply keyboard shown in place of the system keyboard for bots (replyMarkupShowKeyboard).
class ReplyKeyboardPanel extends ConsumerWidget {
  const ReplyKeyboardPanel({super.key, required this.chat, required this.markupMessage, required this.keyboard, required this.onSendText, required this.onHide});

  final td.Chat chat;
  final td.Message markupMessage;
  final td.ReplyMarkupShowKeyboard keyboard;
  final Future<void> Function(String text) onSendText;
  final VoidCallback onHide;

  Future<void> _press(BuildContext context, WidgetRef ref, td.KeyboardButton button) async {
    final account = ref.read(accountProvider);
    final s = context.s;
    switch (button.type) {
      case td.KeyboardButtonTypeText():
        await onSendText(button.text);
      case td.KeyboardButtonTypeRequestPhoneNumber():
        final me = account.me;
        if (me == null) return;
        final ok = await confirm(context, title: s.t('share_phone_title'), message: s.t('share_phone_text', {'bot': chat.title}));
        if (ok && context.mounted) await guard(context, () => account.sendContactCard(chat.id, me));
      case td.KeyboardButtonTypeRequestLocation():
        final ok = await confirm(context, title: s.t('share_location_title'), message: s.t('share_location_text', {'bot': chat.title}));
        if (!ok || !context.mounted) return;
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return;
        final position = await Geolocator.getCurrentPosition();
        if (context.mounted) await guard(context, () => account.sendLocation(chat.id, position.latitude, position.longitude));
      case td.KeyboardButtonTypeWebApp(:final url):
        await openKeyboardWebApp(context, ref, botUserId: account.botUserIdOf(markupMessage), url: url, buttonText: button.text);
      default:
        // Poll/user/chat pickers: send the label so the bot can fall back to text handling.
        await onSendText(button.text);
    }
    if (keyboard.oneTime) onHide();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.4;
    return Container(
      color: scheme.surfaceContainerHighest,
      constraints: BoxConstraints(maxHeight: keyboard.resizeKeyboard ? maxHeight : maxHeight.clamp(0, 280)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(6),
        child: Column(
          children: [
            for (final row in keyboard.rows)
              Row(
                children: [
                  for (final button in row)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Material(
                          color: _styleColor(context, button.style) ?? scheme.surface,
                          borderRadius: BorderRadius.circular(8),
                          elevation: 0.5,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => _press(context, ref, button),
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 44),
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                              child: Text(button.text, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
