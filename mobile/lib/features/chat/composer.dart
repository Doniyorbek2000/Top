import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../contacts/contacts_screen.dart';

class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.chat,
    required this.replyTo,
    required this.editing,
    required this.onCancelReply,
    required this.onCancelEdit,
    required this.onSent,
  });

  final td.Chat chat;
  final td.Message? replyTo;
  final td.Message? editing;
  final VoidCallback onCancelReply;
  final VoidCallback onCancelEdit;
  final VoidCallback onSent;

  @override
  ConsumerState<Composer> createState() => ComposerState();
}

class ComposerState extends ConsumerState<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  AudioRecorder? _recorder;
  late final TelegramAccount _account;
  bool _showEmoji = false;
  bool _hasText = false;
  DateTime _lastTyping = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _draftTimer;

  // Voice recording state.
  bool _recording = false;
  DateTime? _recordStart;
  String? _recordPath;
  final List<int> _waveform = [];
  StreamSubscription<Amplitude>? _amplitudeSub;
  Timer? _recordTicker;
  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();
    // Resolved while mounted: dispose() must not use ref.
    _account = ref.read(accountProvider);
    final draft = widget.chat.draftMessage?.content;
    if (draft is td.DraftMessageContentText) {
      _controller.text = draft.text.text;
      _hasText = _controller.text.trim().isNotEmpty;
    }
    _controller.addListener(_onChanged);
    _focus.addListener(() {
      if (_focus.hasFocus && _showEmoji) setState(() => _showEmoji = false);
    });
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (widget.editing != null && widget.editing!.id != old.editing?.id) {
      _controller.text = messageText(widget.editing!);
      _focus.requestFocus();
    } else if (widget.editing == null && old.editing != null) {
      _controller.clear();
    }
    if (widget.replyTo != null && widget.replyTo!.id != old.replyTo?.id) _focus.requestFocus();
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    if (widget.editing == null) {
      unawaited(_account.saveDraft(widget.chat.id, _controller.text, replyToMessageId: widget.replyTo?.id));
    }
    _amplitudeSub?.cancel();
    _recordTicker?.cancel();
    unawaited(_recorder?.dispose());
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Inserts text at the cursor (used by the AI tools and mentions).
  void setText(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
  }

  void _onChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
    final account = ref.read(accountProvider);
    final ghost = ref.read(settingsProvider).ghostMode;
    if (hasText && !ghost && DateTime.now().difference(_lastTyping) > const Duration(seconds: 4)) {
      _lastTyping = DateTime.now();
      unawaited(account.sendTyping(widget.chat.id, const td.ChatActionTyping()));
    }
    if (widget.editing == null) {
      _draftTimer?.cancel();
      _draftTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) unawaited(account.saveDraft(widget.chat.id, _controller.text, replyToMessageId: widget.replyTo?.id));
      });
    }
  }

  Future<void> _send({bool silent = false, int? scheduleAt}) async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final account = ref.read(accountProvider);
    final editing = widget.editing;
    if (editing != null) {
      final ok = await guard(context, () async {
        await account.editText(editing, text);
        return true;
      });
      if (ok == null) return;
      _controller.clear();
      widget.onCancelEdit();
      return;
    }
    _controller.clear();
    final replyId = widget.replyTo?.id;
    widget.onCancelReply();
    widget.onSent();
    // Telegram limits a message to 4096 characters; split longer texts.
    for (var start = 0; start < text.length; start += 4096) {
      final part = text.substring(start, min(text.length, start + 4096));
      final sent = await guard(
        context,
        () => account.sendText(widget.chat.id, part, replyToId: start == 0 ? replyId : null, silent: silent, scheduleAt: scheduleAt),
      );
      if (sent == null) {
        if (mounted && _controller.text.isEmpty) setText(text);
        return;
      }
    }
  }

  /// Long-press on send: silent or scheduled sending.
  Future<void> _sendOptions() async {
    final s = context.s;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.notifications_off_rounded),
              title: Text(s.t('send_silent')),
              onTap: () => Navigator.pop(context, 'silent'),
            ),
            ListTile(
              leading: const Icon(Icons.schedule_send_rounded),
              title: Text(s.t('send_scheduled')),
              onTap: () => Navigator.pop(context, 'schedule'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'silent') {
      await _send(silent: true);
      return;
    }
    final at = await pickScheduleTime(context);
    if (at != null && mounted) {
      await _send(scheduleAt: at);
      if (mounted) showToast(context, s.t('message_scheduled'));
    }
  }

  // ------------------------------------------------------------------ attachments

  Future<void> _attach() async {
    final s = context.s;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          children: [
            _AttachButton(icon: Icons.photo_library_rounded, color: Colors.blue, label: s.t('gallery'), value: 'gallery'),
            _AttachButton(icon: Icons.photo_camera_rounded, color: Colors.pink, label: s.t('camera'), value: 'camera'),
            _AttachButton(icon: Icons.videocam_rounded, color: Colors.deepPurple, label: s.t('video'), value: 'video'),
            _AttachButton(icon: Icons.insert_drive_file_rounded, color: Colors.teal, label: s.t('file'), value: 'file'),
            _AttachButton(icon: Icons.location_on_rounded, color: Colors.green, label: s.t('location'), value: 'location'),
            _AttachButton(icon: Icons.poll_rounded, color: Colors.orange, label: s.t('poll'), value: 'poll'),
            _AttachButton(icon: Icons.person_rounded, color: Colors.indigo, label: s.t('contact'), value: 'contact'),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final account = ref.read(accountProvider);
    final chatId = widget.chat.id;
    final replyId = widget.replyTo?.id;
    final picker = ImagePicker();
    switch (choice) {
      case 'gallery':
        final files = await picker.pickMultipleMedia(imageQuality: 90);
        for (final file in files) {
          final isVideo = _isVideoPath(file.path);
          if (!mounted) return;
          await guard(context, () => isVideo
              ? account.sendVideo(chatId, file.path, replyToId: replyId)
              : account.sendPhoto(chatId, file.path, replyToId: replyId));
        }
      case 'camera':
        final file = await picker.pickImage(source: ImageSource.camera, imageQuality: 90);
        if (file != null && mounted) await guard(context, () => account.sendPhoto(chatId, file.path, replyToId: replyId));
      case 'video':
        final file = await picker.pickVideo(source: ImageSource.gallery);
        if (file != null && mounted) await guard(context, () => account.sendVideo(chatId, file.path, replyToId: replyId));
      case 'file':
        final files = await FilePicker.pickFiles();
        for (final file in files) {
          final path = file.path;
          if (path == null || !mounted) continue;
          await guard(context, () => account.sendDocument(chatId, path, replyToId: replyId));
        }
      case 'location':
        await _sendLocation();
      case 'poll':
        await _createPoll();
      case 'contact':
        final user = await Navigator.of(context).push<td.User>(
          MaterialPageRoute(builder: (_) => const ContactsScreen(pickUser: true)),
        );
        if (user != null && mounted) await guard(context, () => account.sendContactCard(chatId, user));
    }
    widget.onCancelReply();
    widget.onSent();
  }

  static bool _isVideoPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.mkv') || lower.endsWith('.webm') ||
        lower.endsWith('.3gp');
  }

  Future<void> _sendLocation() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      if (mounted) showToast(context, context.t('location_permission'));
      return;
    }
    final position = await Geolocator.getCurrentPosition();
    if (!mounted) return;
    await guard(context, () => ref.read(accountProvider).sendLocation(widget.chat.id, position.latitude, position.longitude));
  }

  Future<void> _createPoll() async {
    final result = await showDialog<(String, List<String>, bool, bool)>(context: context, builder: (_) => const _PollDialog());
    if (result == null || !mounted) return;
    await guard(
      context,
      () => ref.read(accountProvider).sendPoll(widget.chat.id, result.$1, result.$2, anonymous: result.$3, multiple: result.$4),
    );
  }

  // ------------------------------------------------------------------ voice notes

  Future<void> _startRecording() async {
    if (_recording) return;
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) {
      if (mounted) showToast(context, context.t('mic_permission'));
      return;
    }
    final opus = Platform.isAndroid && await recorder.isEncoderSupported(AudioEncoder.opus);
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.${opus ? 'ogg' : 'm4a'}';
    await recorder.start(
      RecordConfig(encoder: opus ? AudioEncoder.opus : AudioEncoder.aacLc, numChannels: 1, sampleRate: 48000, bitRate: 64000),
      path: path,
    );
    HapticFeedback.mediumImpact();
    _waveform.clear();
    _amplitudeSub = recorder.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((amp) {
      // dBFS (-160..0) mapped to Telegram's 0..31 waveform scale.
      _waveform.add((((amp.current + 50) / 50).clamp(0.0, 1.0) * 31).round());
    });
    _recordTicker = Timer.periodic(const Duration(milliseconds: 200), (_) => setState(() {}));
    if (!ref.read(settingsProvider).ghostMode) {
      unawaited(ref.read(accountProvider).sendTyping(widget.chat.id, const td.ChatActionRecordingVoiceNote()));
    }
    setState(() {
      _recording = true;
      _recordStart = DateTime.now();
      _recordPath = path;
      _dragOffset = 0;
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    if (!_recording) return;
    await _amplitudeSub?.cancel();
    _recordTicker?.cancel();
    final path = await _recorder?.stop() ?? _recordPath;
    final duration = DateTime.now().difference(_recordStart!);
    setState(() => _recording = false);
    if (!send || path == null || duration < const Duration(milliseconds: 700)) {
      if (path != null) unawaited(File(path).delete().catchError((Object _) => File(path)));
      return;
    }
    // Downsample to Telegram's 100-sample waveform.
    final samples = _waveform.isEmpty
        ? <int>[]
        : List<int>.generate(100, (i) => _waveform[(i * _waveform.length / 100).floor()]);
    if (!mounted) return;
    final replyId = widget.replyTo?.id;
    widget.onCancelReply();
    widget.onSent();
    await guard(
      context,
      () => ref.read(accountProvider).sendVoice(widget.chat.id, path, durationSeconds: max(1, duration.inSeconds), waveform: samples, replyToId: replyId),
    );
  }

  // ------------------------------------------------------------------ Telegram AI

  Future<void> _aiTools() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final account = ref.read(accountProvider);
    final s = context.s;
    final styles = account.compositionStyles;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(leading: const Icon(Icons.spellcheck_rounded), title: Text(s.t('ai_fix')), onTap: () => Navigator.pop(context, 'fix')),
              ListTile(
                leading: const Icon(Icons.translate_rounded),
                title: Text(s.t('ai_translate_to', {'lang': Strings.languageNames[s.locale] ?? s.locale})),
                onTap: () => Navigator.pop(context, 'translate'),
              ),
              ListTile(
                leading: const Icon(Icons.emoji_emotions_rounded),
                title: Text(s.t('ai_add_emoji')),
                onTap: () => Navigator.pop(context, 'emoji'),
              ),
              for (final style in styles)
                ListTile(
                  leading: const Icon(Icons.auto_awesome_rounded),
                  title: Text(style.title),
                  onTap: () => Navigator.pop(context, 'style:${style.name}'),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final settings = ref.read(settingsProvider);
    final result = await guard(context, () {
      if (choice == 'fix') return account.fixWithAi(text);
      if (choice == 'translate') return account.translate(text, settings.localeCode);
      if (choice == 'emoji') return account.composeWithAi(text, addEmojis: true);
      return account.composeWithAi(text, styleName: choice.substring(6));
    });
    if (result != null && mounted) setText(result);
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final settings = ref.watch(settingsProvider);
    final s = context.s;
    final theme = Theme.of(context);
    final chat = widget.chat;

    if (!account.isMember(chat) &&
        (account.isChannel(chat) || account.isGroup(chat))) {
      return _BottomAction(
        label: s.t(account.isChannel(chat) ? 'join_channel' : 'join_group'),
        onTap: () => guard(context, () => account.send<td.Ok>(td.JoinChat(chatId: chat.id))),
      );
    }
    if (!account.canSendMessages(chat)) {
      final muted = account.isMuted(chat);
      if (account.isChannel(chat)) {
        return _BottomAction(
          label: s.t(muted ? 'unmute' : 'mute'),
          onTap: () => guard(context, () => account.setMuted(chat, muted ? 0 : muteForever)),
        );
      }
      final user = account.privateUser(chat);
      if (user != null && chat.blockList != null) {
        return _BottomAction(
          label: s.t('unblock'),
          onTap: () => guard(context, () => account.send<td.Ok>(
                td.SetMessageSenderBlockList(senderId: td.MessageSenderUser(userId: user.id), blockList: null),
              )),
        );
      }
      return _BottomAction(label: s.t('cannot_send'), onTap: null);
    }

    final reference = widget.editing ?? widget.replyTo;
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reference != null)
              _ReferenceBar(
                message: reference,
                editing: widget.editing != null,
                onClose: widget.editing != null ? widget.onCancelEdit : widget.onCancelReply,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: _recording ? _recordingRow(s) : _inputRow(s, settings),
            ),
            if (_showEmoji)
              SizedBox(
                height: 280,
                child: EmojiPicker(
                  textEditingController: _controller,
                  config: Config(
                    height: 280,
                    emojiViewConfig: EmojiViewConfig(backgroundColor: theme.colorScheme.surface, emojiSizeMax: 30),
                    categoryViewConfig: CategoryViewConfig(
                      backgroundColor: theme.colorScheme.surface,
                      indicatorColor: theme.colorScheme.primary,
                      iconColorSelected: theme.colorScheme.primary,
                    ),
                    bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
                    searchViewConfig: SearchViewConfig(backgroundColor: theme.colorScheme.surface),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _inputRow(Strings s, AppSettings settings) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        IconButton(
          icon: Icon(_showEmoji ? Icons.keyboard_rounded : Icons.emoji_emotions_outlined, color: theme.hintColor),
          onPressed: () {
            setState(() => _showEmoji = !_showEmoji);
            if (_showEmoji) {
              _focus.unfocus();
            } else {
              _focus.requestFocus();
            }
          },
        ),
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            minLines: 1,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            keyboardType: TextInputType.multiline,
            textInputAction: settings.sendByEnter ? TextInputAction.send : TextInputAction.newline,
            onSubmitted: settings.sendByEnter ? (_) => _send() : null,
            style: TextStyle(fontSize: 16 * settings.textScale),
            decoration: InputDecoration(
              hintText: s.t('message_hint'),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        if (_hasText && widget.editing == null)
          IconButton(
            tooltip: 'Telegram AI',
            icon: Icon(Icons.auto_awesome_rounded, color: theme.colorScheme.primary),
            onPressed: _aiTools,
          ),
        if (!_hasText && widget.editing == null)
          IconButton(icon: Icon(Icons.attach_file_rounded, color: theme.hintColor), onPressed: _attach),
        if (_hasText || widget.editing != null)
          GestureDetector(
            onLongPress: widget.editing == null ? _sendOptions : null,
            child: IconButton(
              icon: Icon(widget.editing != null ? Icons.check_circle_rounded : Icons.send_rounded, color: theme.colorScheme.primary),
              onPressed: _send,
            ),
          )
        else
          GestureDetector(
            onLongPressStart: (_) => _startRecording(),
            onLongPressMoveUpdate: (details) {
              setState(() => _dragOffset = details.offsetFromOrigin.dx);
              if (_dragOffset < -120) _stopRecording(send: false);
            },
            onLongPressEnd: (_) => _stopRecording(send: _dragOffset > -120),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Icon(Icons.mic_rounded, color: theme.hintColor),
            ),
          ),
      ],
    );
  }

  Widget _recordingRow(Strings s) {
    final elapsed = DateTime.now().difference(_recordStart ?? DateTime.now());
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: 12),
          const Icon(Icons.fiber_manual_record_rounded, color: Colors.redAccent, size: 14),
          const SizedBox(width: 8),
          Text(formatDuration(elapsed), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
          Expanded(
            child: Transform.translate(
              offset: Offset(max(-80, _dragOffset / 2), 0),
              child: Center(
                child: Text('‹  ${s.t('slide_to_cancel')}', style: TextStyle(color: Theme.of(context).hintColor)),
              ),
            ),
          ),
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle),
            child: const Icon(Icons.mic_rounded, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _BottomAction extends StatelessWidget {
  const _BottomAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: false,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 52,
              width: double.infinity,
              child: Center(
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    color: onTap == null ? Theme.of(context).hintColor : Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class _ReferenceBar extends ConsumerWidget {
  const _ReferenceBar({required this.message, required this.editing, required this.onClose});

  final td.Message message;
  final bool editing;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
      child: Row(
        children: [
          Icon(editing ? Icons.edit_rounded : Icons.reply_rounded, color: primary),
          const SizedBox(width: 10),
          Container(width: 2, height: 36, color: primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  editing ? s.t('editing') : account.senderName(message.senderId),
                  style: TextStyle(color: primary, fontWeight: FontWeight.w600, fontSize: 14),
                ),
                Text(
                  messagePreview(message, account, s).replaceAll('\n', ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.close_rounded), onPressed: onClose),
        ],
      ),
    );
  }
}

class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.icon, required this.color, required this.label, required this.value});

  final IconData icon;
  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.pop(context, value),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(radius: 26, backgroundColor: color, child: Icon(icon, color: Colors.white)),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 12.5), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      );
}

class _PollDialog extends StatefulWidget {
  const _PollDialog();

  @override
  State<_PollDialog> createState() => _PollDialogState();
}

class _PollDialogState extends State<_PollDialog> {
  final _question = TextEditingController();
  final List<TextEditingController> _options = [TextEditingController(), TextEditingController()];
  bool _anonymous = true;
  bool _multiple = false;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return AlertDialog(
      title: Text(s.t('new_poll')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _question, decoration: InputDecoration(labelText: s.t('poll_question'))),
            const SizedBox(height: 8),
            for (var i = 0; i < _options.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: TextField(controller: _options[i], decoration: InputDecoration(labelText: '${s.t('poll_option')} ${i + 1}')),
              ),
            if (_options.length < 10)
              TextButton.icon(
                onPressed: () => setState(() => _options.add(TextEditingController())),
                icon: const Icon(Icons.add_rounded),
                label: Text(s.t('poll_add_option')),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.t('poll_anonymous')),
              value: _anonymous,
              onChanged: (v) => setState(() => _anonymous = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.t('poll_multiple')),
              value: _multiple,
              onChanged: (v) => setState(() => _multiple = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
        TextButton(
          onPressed: () {
            final options = _options.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
            if (_question.text.trim().isEmpty || options.length < 2) {
              showToast(context, s.t('poll_invalid'));
              return;
            }
            Navigator.pop(context, (_question.text.trim(), options, _anonymous, _multiple));
          },
          child: Text(s.t('send')),
        ),
      ],
    );
  }
}

/// Date + time picker for scheduled messages; returns a unix timestamp in the future or null.
Future<int?> pickScheduleTime(BuildContext context) async {
  final now = DateTime.now();
  final date = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 365)), initialDate: now);
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 10))));
  if (time == null) return null;
  final at = DateTime(date.year, date.month, date.day, time.hour, time.minute);
  if (!at.isAfter(now.add(const Duration(seconds: 30)))) return null;
  return at.millisecondsSinceEpoch ~/ 1000;
}
