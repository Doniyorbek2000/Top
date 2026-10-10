import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/tdlib/td_client.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/chat_history.dart';
import '../../widgets/common.dart';
import 'message_content.dart';

/// Official Telegram sponsored message, rendered as Telegram requires: clearly labelled, with the
/// sponsor's button, an "About" disclosure and a report option. Views are reported only once the
/// whole message is on screen.
class SponsoredBubble extends ConsumerStatefulWidget {
  const SponsoredBubble({super.key, required this.message, required this.history});

  final td.SponsoredMessage message;
  final ChatHistory history;

  @override
  ConsumerState<SponsoredBubble> createState() => _SponsoredBubbleState();
}

class _SponsoredBubbleState extends ConsumerState<SponsoredBubble> {
  Timer? _visibilityTimer;

  @override
  void initState() {
    super.initState();
    _visibilityTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _checkVisible());
  }

  @override
  void dispose() {
    _visibilityTimer?.cancel();
    super.dispose();
  }

  void _checkVisible() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final screen = MediaQuery.sizeOf(context).height;
    if (top >= 0 && bottom <= screen) {
      widget.history.markSponsoredViewed(widget.message.messageId);
      _visibilityTimer?.cancel();
    }
  }

  Future<void> _open() async {
    await guard(context, () => widget.history.clickSponsored(widget.message));
    final uri = Uri.tryParse(widget.message.sponsor.url);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _report() async {
    final account = widget.history.account;
    final s = context.s;
    var optionId = '';
    for (var step = 0; step < 5; step++) {
      td.ReportSponsoredResult result;
      try {
        result = await account.send<td.ReportSponsoredResult>(td.ReportChatSponsoredMessage(
          chatId: widget.history.chatId,
          messageId: widget.message.messageId,
          optionId: optionId,
        ));
      } on TdException catch (error) {
        if (mounted) showError(context, error);
        return;
      }
      if (!mounted) return;
      if (result case td.ReportSponsoredResultOptionRequired(:final title, :final options)) {
        final chosen = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(padding: const EdgeInsets.all(12), child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                for (final option in options)
                  ListTile(title: Text(option.text), onTap: () => Navigator.pop(context, option.id)),
              ],
            ),
          ),
        );
        if (chosen == null) return;
        optionId = chosen;
        continue;
      }
      showToast(context, s.t(switch (result) {
        td.ReportSponsoredResultOk() => 'ad_reported',
        td.ReportSponsoredResultAdsHidden() => 'ad_hidden',
        td.ReportSponsoredResultPremiumRequired() => 'ad_premium_required',
        _ => 'err_GENERIC',
      }));
      return;
    }
  }

  void _about() {
    final s = context.s;
    final info = [widget.message.sponsor.info, widget.message.additionalInfo].where((t) => t != null && t.isNotEmpty).join('\n\n');
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('ad_about_title')),
        content: Text([s.t('ad_about_text'), if (info.isNotEmpty) info].join('\n\n')),
        actions: [
          TextButton(
            onPressed: () => launchUrl(Uri.parse('https://promote.telegram.org'), mode: LaunchMode.externalApplication),
            child: Text(s.t('ad_learn_more')),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('ok'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final colors = context.chatColors;
    final message = widget.message;
    final primary = theme.colorScheme.primary;
    final text = switch (message.content) {
      td.MessageText(:final text) => text,
      _ => null,
    };
    final maxWidth = MediaQuery.sizeOf(context).width * 0.78;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          decoration: BoxDecoration(
            color: colors.incomingBubble,
            borderRadius: BorderRadius.circular(16),
            border: Border(left: BorderSide(color: primary, width: 3)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    s.t(message.isRecommended ? 'ad_recommended' : 'ad_label'),
                    style: TextStyle(color: primary, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const Spacer(),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: s.t('ad_about_title'),
                    icon: Icon(Icons.info_outline_rounded, size: 18, color: theme.hintColor),
                    onPressed: _about,
                  ),
                  if (message.canBeReported)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: s.t('ad_report'),
                      icon: Icon(Icons.flag_outlined, size: 18, color: theme.hintColor),
                      onPressed: _report,
                    ),
                ],
              ),
              if (message.title.isNotEmpty) Text(message.title, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (text != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: FormattedTextView(text: text, style: TextStyle(color: colors.incomingText, fontSize: 15)),
                ),
              if (message.buttonText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 4),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(onPressed: _open, child: Text(message.buttonText.toUpperCase())),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
