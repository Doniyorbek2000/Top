import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

int _rgb(Color color) => color.toARGB32() & 0xFFFFFF;

String _hex(int rgb) => '#${rgb.toRadixString(16).padLeft(6, '0')}';

/// Telegram Mini App theme derived from the current Material theme.
td.ThemeParameters themeParametersOf(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  return td.ThemeParameters(
    backgroundColor: _rgb(scheme.surface),
    secondaryBackgroundColor: _rgb(scheme.surfaceContainerHighest),
    headerBackgroundColor: _rgb(theme.appBarTheme.backgroundColor ?? scheme.primary),
    bottomBarBackgroundColor: _rgb(scheme.surface),
    sectionBackgroundColor: _rgb(scheme.surface),
    sectionSeparatorColor: _rgb(theme.dividerColor),
    textColor: _rgb(scheme.onSurface),
    accentTextColor: _rgb(scheme.primary),
    sectionHeaderTextColor: _rgb(scheme.primary),
    subtitleTextColor: _rgb(theme.hintColor),
    destructiveTextColor: _rgb(scheme.error),
    hintColor: _rgb(theme.hintColor),
    linkColor: _rgb(scheme.primary),
    buttonColor: _rgb(scheme.primary),
    buttonTextColor: _rgb(scheme.onPrimary),
  );
}

Map<String, String> _themeJson(td.ThemeParameters t) => {
      'bg_color': _hex(t.backgroundColor),
      'secondary_bg_color': _hex(t.secondaryBackgroundColor),
      'header_bg_color': _hex(t.headerBackgroundColor),
      'bottom_bar_bg_color': _hex(t.bottomBarBackgroundColor),
      'section_bg_color': _hex(t.sectionBackgroundColor),
      'section_separator_color': _hex(t.sectionSeparatorColor),
      'text_color': _hex(t.textColor),
      'accent_text_color': _hex(t.accentTextColor),
      'section_header_text_color': _hex(t.sectionHeaderTextColor),
      'subtitle_text_color': _hex(t.subtitleTextColor),
      'destructive_text_color': _hex(t.destructiveTextColor),
      'hint_color': _hex(t.hintColor),
      'link_color': _hex(t.linkColor),
      'button_color': _hex(t.buttonColor),
      'button_text_color': _hex(t.buttonTextColor),
    };

/// Opens a Mini App from an inline keyboard button or a bot link.
Future<void> openInlineWebApp(BuildContext context, WidgetRef ref, {required int chatId, required int botUserId, required String url}) async {
  final account = ref.read(accountProvider);
  final theme = themeParametersOf(context);
  final info = await guard(context, () => account.openWebApp(chatId, botUserId, url, theme));
  if (info == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => WebAppScreen(url: info.url.url, botUserId: botUserId, launchId: info.launchId),
  ));
}

/// Opens a Mini App from a reply keyboard button; it may send data back to the bot.
Future<void> openKeyboardWebApp(BuildContext context, WidgetRef ref, {required int botUserId, required String url, required String buttonText}) async {
  final account = ref.read(accountProvider);
  final theme = themeParametersOf(context);
  final appUrl = await guard(context, () => account.webAppUrl(botUserId, url, theme));
  if (appUrl == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => WebAppScreen(url: appUrl, botUserId: botUserId, keyboardButtonText: buttonText),
  ));
}

/// Hosts a Telegram Mini App. Implements the subset of the WebView bridge most apps rely on: close,
/// main/back buttons, popups, theme and viewport, opening links and sending data to the bot.
class WebAppScreen extends ConsumerStatefulWidget {
  const WebAppScreen({super.key, required this.url, required this.botUserId, this.launchId, this.keyboardButtonText});

  final String url;
  final int botUserId;
  final int? launchId;
  final String? keyboardButtonText;

  @override
  ConsumerState<WebAppScreen> createState() => _WebAppScreenState();
}

class _MainButton {
  const _MainButton({required this.visible, required this.text, required this.active, this.color, this.textColor, this.progress = false});

  final bool visible;
  final String text;
  final bool active;
  final Color? color;
  final Color? textColor;
  final bool progress;
}

Color? _parseColor(Object? value) {
  if (value is! String || !value.startsWith('#') || value.length != 7) return null;
  final rgb = int.tryParse(value.substring(1), radix: 16);
  return rgb == null ? null : Color(0xFF000000 | rgb);
}

class _WebAppScreenState extends ConsumerState<WebAppScreen> {
  late final WebViewController _controller;
  _MainButton _mainButton = const _MainButton(visible: false, text: '', active: true);
  bool _backButton = false;
  bool _loading = true;
  bool _confirmClose = false;
  String _title = '';
  Color? _headerColor;

  static const _bridge = '''
(function() {
  if (window.TelegramWebviewProxy) return;
  window.TelegramWebviewProxy = {
    postEvent: function(eventType, eventData) {
      SadoWebAppBridge.postMessage(JSON.stringify({type: eventType, data: eventData || ''}));
    }
  };
})();
''';

  @override
  void initState() {
    super.initState();
    final account = ref.read(accountProvider);
    _title = account.userName(widget.botUserId);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('SadoWebAppBridge', onMessageReceived: (message) => _onBridgeMessage(message.message))
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => unawaited(_controller.runJavaScript(_bridge)),
        onPageFinished: (_) async {
          await _controller.runJavaScript(_bridge);
          if (mounted) setState(() => _loading = false);
          _sendViewport();
        },
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          if (uri != null && (uri.scheme == 'tg' || uri.host == 't.me')) {
            unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  void dispose() {
    final launchId = widget.launchId;
    if (launchId != null) unawaited(ref.read(accountProvider).closeWebApp(launchId));
    super.dispose();
  }

  void _emit(String type, [Object? data]) {
    final payload = data == null ? 'null' : jsonEncode(data);
    unawaited(_controller.runJavaScript(
      'window.Telegram && window.Telegram.WebView && window.Telegram.WebView.receiveEvent(${jsonEncode(type)}, $payload);',
    ));
  }

  void _sendViewport() {
    if (!mounted) return;
    final height = MediaQuery.sizeOf(context).height;
    _emit('viewport_changed', {'height': height, 'is_expanded': true, 'is_state_stable': true});
  }

  Map<String, dynamic> _decodeData(Object? raw) {
    if (raw is Map) return raw.cast<String, dynamic>();
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return decoded.cast<String, dynamic>();
      } on FormatException {
        return const {};
      }
    }
    return const {};
  }

  Future<void> _onBridgeMessage(String raw) async {
    Map<String, dynamic> event;
    try {
      event = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } on Object {
      return;
    }
    final type = event['type'] as String? ?? '';
    final data = _decodeData(event['data']);
    final account = ref.read(accountProvider);
    switch (type) {
      case 'web_app_close':
        if (mounted) Navigator.of(context).pop();
      case 'web_app_ready' || 'web_app_expand' || 'web_app_request_viewport':
        _sendViewport();
      case 'web_app_request_theme':
        _emit('theme_changed', {'theme_params': _themeJson(themeParametersOf(context))});
      case 'web_app_setup_main_button':
        setState(() => _mainButton = _MainButton(
              visible: data['is_visible'] == true && (data['text'] as String? ?? '').trim().isNotEmpty,
              text: data['text'] as String? ?? '',
              active: data['is_active'] != false,
              color: _parseColor(data['color']),
              textColor: _parseColor(data['text_color']),
              progress: data['is_progress_visible'] == true,
            ));
      case 'web_app_setup_back_button':
        setState(() => _backButton = data['is_visible'] == true);
      case 'web_app_setup_closing_behavior':
        _confirmClose = data['need_confirmation'] == true;
      case 'web_app_set_header_color':
        setState(() => _headerColor = _parseColor(data['color']));
      case 'web_app_open_link':
        final uri = Uri.tryParse(data['url'] as String? ?? '');
        if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      case 'web_app_open_tg_link':
        final path = data['path_full'] as String? ?? '';
        if (path.startsWith('/')) await launchUrl(Uri.parse('https://t.me$path'), mode: LaunchMode.externalApplication);
      case 'web_app_data_send':
        final buttonText = widget.keyboardButtonText;
        final payload = data['data'] as String? ?? '';
        if (buttonText != null && payload.isNotEmpty && payload.length <= 4096) {
          await guard(context, () => account.sendWebAppData(widget.botUserId, buttonText, payload));
          if (mounted) Navigator.of(context).pop();
        }
      case 'web_app_open_popup':
        await _showPopup(data);
      case 'web_app_read_text_from_clipboard':
        _emit('clipboard_text_received', {'req_id': data['req_id']});
      default:
        break;
    }
  }

  Future<void> _showPopup(Map<String, dynamic> data) async {
    final buttons = (data['buttons'] as List?)?.whereType<Map>().map((b) => b.cast<String, dynamic>()).toList() ?? const [];
    final s = context.s;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: (data['title'] as String?)?.isNotEmpty == true ? Text(data['title'] as String) : null,
        content: Text(data['message'] as String? ?? ''),
        actions: [
          for (final button in buttons.isEmpty ? [<String, dynamic>{'id': '', 'type': 'close'}] : buttons)
            TextButton(
              onPressed: () => Navigator.pop(context, button['id'] as String? ?? ''),
              style: button['type'] == 'destructive' ? TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error) : null,
              child: Text(switch (button['type']) {
                'ok' => s.t('ok'),
                'close' => s.t('close'),
                'cancel' => s.t('cancel'),
                _ => button['text'] as String? ?? '',
              }),
            ),
        ],
      ),
    );
    _emit('popup_closed', chosen == null ? <String, dynamic>{} : {'button_id': chosen});
  }

  Future<bool> _handleBack() async {
    if (_backButton) {
      _emit('back_button_pressed');
      return false;
    }
    if (_confirmClose) {
      return confirm(context, title: context.t('webapp_close_title'), message: context.t('webapp_close_confirm'));
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final button = _mainButton;
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _handleBack()) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: _headerColor,
          leading: IconButton(
            icon: Icon(_backButton ? Icons.arrow_back_rounded : Icons.close_rounded),
            onPressed: () async {
              final navigator = Navigator.of(context);
              if (await _handleBack()) navigator.pop();
            },
          ),
          title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            PopupMenuButton<String>(
              onSelected: (value) async {
                switch (value) {
                  case 'reload':
                    await _controller.reload();
                  case 'settings':
                    _emit('settings_button_pressed');
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(value: 'reload', child: Text(context.t('reload'))),
                PopupMenuItem(value: 'settings', child: Text(context.t('settings'))),
              ],
            ),
          ],
        ),
        body: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
          ],
        ),
        bottomNavigationBar: button.visible
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: button.color ?? scheme.primary,
                      foregroundColor: button.textColor ?? scheme.onPrimary,
                    ),
                    onPressed: button.active ? () => _emit('main_button_pressed') : null,
                    child: button.progress
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(button.text),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}
