import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lottie/lottie.dart';
import 'package:open_filex/open_filex.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../core/formatters.dart';
import '../../core/live_location.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import 'bot_keyboard.dart';
import 'media_viewers.dart';

/// Picks the photo size best suited for a bubble (around 800px wide).
td.PhotoSize? bestPhotoSize(td.Photo photo, {int target = 800}) {
  if (photo.sizes.isEmpty) return null;
  final sorted = [...photo.sizes]..sort((a, b) => a.width.compareTo(b.width));
  return sorted.firstWhere((s) => s.width >= target, orElse: () => sorted.last);
}

/// Renders a FormattedText with Telegram entities (links, mentions, bold, code, spoilers...).
class FormattedTextView extends StatefulWidget {
  const FormattedTextView({super.key, required this.text, this.style, this.onMention, this.trailingSpace = 0});

  final td.FormattedText text;
  final TextStyle? style;

  /// Invisible room at the end of the last line (the bubble draws the time there when it fits).
  final double trailingSpace;
  final void Function(String username)? onMention;

  @override
  State<FormattedTextView> createState() => _FormattedTextViewState();
}

class _FormattedTextViewState extends State<FormattedTextView> {
  final List<TapGestureRecognizer> _recognizers = [];
  final Set<int> _revealedSpoilers = {};

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final recognizer = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(recognizer);
    return recognizer;
  }

  void _openUrl(String url) {
    final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
    if (uri != null) unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final text = widget.text.text;
    final entities = [...widget.text.entities]..sort((a, b) => a.offset.compareTo(b.offset));
    final linkColor = Theme.of(context).colorScheme.primary;
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < entities.length; i++) {
      final entity = entities[i];
      final start = entity.offset.clamp(0, text.length);
      final end = (entity.offset + entity.length).clamp(start, text.length);
      if (start < cursor) continue; // nested entities: keep the outer one
      if (start > cursor) spans.add(TextSpan(text: text.substring(cursor, start)));
      final part = text.substring(start, end);
      spans.add(_entitySpan(entity.type, part, i, linkColor, base));
      cursor = end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    if (widget.trailingSpace > 0) spans.add(WidgetSpan(child: SizedBox(width: widget.trailingSpace, height: 1)));
    return Text.rich(TextSpan(style: base, children: spans));
  }

  InlineSpan _entitySpan(td.TextEntityType type, String part, int index, Color linkColor, TextStyle base) {
    final link = TextStyle(color: linkColor, decoration: TextDecoration.underline, decorationColor: linkColor);
    switch (type) {
      case td.TextEntityTypeUrl():
        return TextSpan(text: part, style: link, recognizer: _tap(() => _openUrl(part)));
      case td.TextEntityTypeTextUrl(:final url):
        return TextSpan(text: part, style: link, recognizer: _tap(() => _openUrl(url)));
      case td.TextEntityTypeEmailAddress():
        return TextSpan(text: part, style: link, recognizer: _tap(() => launchUrl(Uri(scheme: 'mailto', path: part))));
      case td.TextEntityTypePhoneNumber():
        return TextSpan(text: part, style: link, recognizer: _tap(() => launchUrl(Uri(scheme: 'tel', path: part))));
      case td.TextEntityTypeMention():
        return TextSpan(
          text: part,
          style: TextStyle(color: linkColor),
          recognizer: _tap(() => widget.onMention?.call(part.substring(1))),
        );
      case td.TextEntityTypeMentionName() || td.TextEntityTypeHashtag() || td.TextEntityTypeCashtag():
        return TextSpan(text: part, style: TextStyle(color: linkColor));
      case td.TextEntityTypeBold():
        return TextSpan(text: part, style: const TextStyle(fontWeight: FontWeight.w700));
      case td.TextEntityTypeItalic():
        return TextSpan(text: part, style: const TextStyle(fontStyle: FontStyle.italic));
      case td.TextEntityTypeUnderline():
        return TextSpan(text: part, style: const TextStyle(decoration: TextDecoration.underline));
      case td.TextEntityTypeStrikethrough():
        return TextSpan(text: part, style: const TextStyle(decoration: TextDecoration.lineThrough));
      case td.TextEntityTypeCode() || td.TextEntityTypePre() || td.TextEntityTypePreCode():
        return TextSpan(
          text: part,
          style: TextStyle(fontFamily: 'monospace', color: linkColor, fontSize: (base.fontSize ?? 15) - 1),
          recognizer: _tap(() => Clipboard.setData(ClipboardData(text: part))),
        );
      case td.TextEntityTypeSpoiler():
        final revealed = _revealedSpoilers.contains(index);
        return TextSpan(
          text: part,
          style: revealed ? null : TextStyle(color: Colors.transparent, backgroundColor: base.color?.withValues(alpha: 0.35)),
          recognizer: _tap(() => setState(() => _revealedSpoilers.add(index))),
        );
      case td.TextEntityTypeBlockQuote() || td.TextEntityTypeExpandableBlockQuote():
        return TextSpan(text: part, style: const TextStyle(fontStyle: FontStyle.italic));
      default:
        return TextSpan(text: part);
    }
  }
}

/// Media and special content of a message (text is rendered by the bubble).
class MessageMedia extends ConsumerWidget {
  const MessageMedia({super.key, required this.message, required this.maxWidth});

  final td.Message message;
  final double maxWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content = message.content;
    return switch (content) {
      td.MessagePhoto(:final photo, :final hasSpoiler) => _PhotoView(photo: photo, maxWidth: maxWidth, spoiler: hasSpoiler),
      td.MessageVideo(:final video) => _VideoThumb(
          file: video.video,
          thumbnail: video.thumbnail,
          minithumbnail: video.minithumbnail,
          width: video.width,
          height: video.height,
          duration: video.duration,
          maxWidth: maxWidth,
        ),
      td.MessageAnimation(:final animation) => _VideoThumb(
          file: animation.animation,
          thumbnail: animation.thumbnail,
          minithumbnail: animation.minithumbnail,
          width: animation.width,
          height: animation.height,
          duration: animation.duration,
          maxWidth: maxWidth,
          isGif: true,
        ),
      td.MessageVideoNote(:final videoNote) => _VideoThumb(
          file: videoNote.video,
          thumbnail: videoNote.thumbnail,
          minithumbnail: videoNote.minithumbnail,
          width: videoNote.length,
          height: videoNote.length,
          duration: videoNote.duration,
          maxWidth: min(maxWidth, 220),
          round: true,
        ),
      td.MessageVoiceNote(:final voiceNote) => VoiceNoteView(message: message, voiceNote: voiceNote),
      td.MessageAudio(:final audio) => _FileView(
          message: message,
          file: audio.audio,
          name: [audio.performer, audio.title].where((p) => p.isNotEmpty).join(' — ').ifEmpty(audio.fileName),
          icon: Icons.music_note_rounded,
          mimeType: audio.mimeType,
        ),
      td.MessageDocument(:final document) => _FileView(
          message: message,
          file: document.document,
          name: document.fileName,
          icon: Icons.insert_drive_file_rounded,
          mimeType: document.mimeType,
        ),
      td.MessageSticker(:final sticker) => _StickerView(sticker: sticker),
      td.MessageLocation(:final location) => _LocationView(latitude: location.latitude, longitude: location.longitude),
      td.MessageLiveLocation(:final location, :final expiresIn) => _LiveLocationView(message: message, location: location, expiresIn: expiresIn),
      td.MessageVenue(:final venue) =>
        _LocationView(latitude: venue.location.latitude, longitude: venue.location.longitude, title: venue.title, subtitle: venue.address),
      td.MessageContact(:final contact) => _ContactView(contact: contact),
      td.MessagePoll(:final poll) => PollView(message: message, poll: poll),
      td.MessageCall(:final isVideo, :final duration) => _CallView(isVideo: isVideo, duration: duration, outgoing: message.isOutgoing),
      td.MessageInvoice() => InvoiceView(message: message),
      td.MessageAnimatedEmoji(:final emoji) || td.MessageDice(:final emoji) =>
        Text(emoji, style: const TextStyle(fontSize: 56)),
      _ => const SizedBox.shrink(),
    };
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

Size _fit(int width, int height, double maxWidth, {double maxHeight = 380}) {
  if (width <= 0 || height <= 0) return Size(maxWidth, maxWidth * 0.75);
  var w = maxWidth;
  var h = w * height / width;
  if (h > maxHeight) {
    h = maxHeight;
    w = h * width / height;
  }
  return Size(max(w, 120), max(h, 80));
}

class _PhotoView extends StatefulWidget {
  const _PhotoView({required this.photo, required this.maxWidth, required this.spoiler});

  final td.Photo photo;
  final double maxWidth;
  final bool spoiler;

  @override
  State<_PhotoView> createState() => _PhotoViewState();
}

class _PhotoViewState extends State<_PhotoView> {
  late bool _hidden = widget.spoiler;
  bool _requested = false;

  @override
  Widget build(BuildContext context) {
    final size = bestPhotoSize(widget.photo);
    if (size == null) return const SizedBox.shrink();
    final box = _fit(size.width, size.height, widget.maxWidth);
    return Consumer(builder: (context, ref, _) {
      final auto = ref.watch(settingsProvider.select((s) => s.autoDownloadPhotos));
      final download = auto || _requested || size.photo.local.isDownloadingCompleted;
      final image = TdImage(file: size.photo, minithumbnail: widget.photo.minithumbnail, width: box.width, height: box.height, download: download);
      return GestureDetector(
        onTap: () {
          if (!download) {
            setState(() => _requested = true);
            return;
          }
          if (_hidden) {
            setState(() => _hidden = false);
            return;
          }
        final full = bestPhotoSize(widget.photo, target: 2560)!;
        openPhotoViewer(context, full.photo, widget.photo.minithumbnail);
      },
        child: SizedBox(
          width: box.width,
          height: box.height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _hidden ? ImageFiltered(imageFilter: _blur, child: image) : image,
              if (!download)
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                    child: const Icon(Icons.download_rounded, color: Colors.white, size: 28),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

final _blur = ImageFilter.blur(sigmaX: 18, sigmaY: 18);

class _VideoThumb extends ConsumerWidget {
  const _VideoThumb({
    required this.file,
    required this.thumbnail,
    required this.minithumbnail,
    required this.width,
    required this.height,
    required this.duration,
    required this.maxWidth,
    this.isGif = false,
    this.round = false,
  });

  final td.File file;
  final td.Thumbnail? thumbnail;
  final td.Minithumbnail? minithumbnail;
  final int width;
  final int height;
  final int duration;
  final double maxWidth;
  final bool isGif;
  final bool round;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = _fit(width, height, maxWidth);
    final thumb = thumbnail;
    Widget preview = thumb != null && thumb.format is! td.ThumbnailFormatMpeg4
        ? TdImage(file: thumb.file, minithumbnail: minithumbnail, width: box.width, height: box.height)
        : Container(width: box.width, height: box.height, color: Colors.black26);
    if (isGif && ref.watch(settingsProvider.select((s) => s.autoplayGifs))) {
      // GIFs are small MP4s: download and loop them inline like Telegram.
      final current = ref.watch(fileProvider(file.id)).value ?? file;
      if (current.local.isDownloadingCompleted && current.local.path.isNotEmpty) {
        return GestureDetector(
          onTap: () => openVideoPlayer(context, file, loop: true),
          child: SizedBox(
            width: box.width,
            height: box.height,
            child: ClipRect(child: LoopingVideo(key: ValueKey(current.local.path), path: current.local.path, fallback: preview)),
          ),
        );
      }
    }
    if (round) preview = ClipOval(child: preview);
    return GestureDetector(
      onTap: () => openVideoPlayer(context, file, loop: isGif),
      child: Stack(
        alignment: Alignment.center,
        children: [
          preview,
          Container(
            decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
            padding: const EdgeInsets.all(10),
            child: Icon(isGif ? Icons.gif_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 30),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
              child: Text(
                isGif ? 'GIF' : '${formatDuration(Duration(seconds: duration))}  ${formatFileSize(file.size == 0 ? file.expectedSize : file.size)}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileView extends ConsumerWidget {
  const _FileView({required this.message, required this.file, required this.name, required this.icon, required this.mimeType});

  final td.Message message;
  final td.File file;
  final String name;
  final IconData icon;
  final String mimeType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final current = ref.watch(_fileStateProvider(file.id)).value ?? account.files[file.id] ?? file;
    final total = current.size == 0 ? current.expectedSize : current.size;
    final done = current.local.isDownloadingCompleted;
    final downloading = current.local.isDownloadingActive;
    final progress = total > 0 ? current.local.downloadedSize / total : null;
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () async {
        if (done) {
          await OpenFilex.open(current.local.path, type: mimeType.isEmpty ? null : mimeType);
        } else if (downloading) {
          account.cancelDownload(file.id);
        } else {
          // Registered in TDLib's download list so it appears (and can be paused) in Downloads.
          await account.addToDownloads(message, file.id, priority: 32).catchError((Object _) {});
          final path = await account.downloadFile(file.id, priority: 32);
          if (path != null) await OpenFilex.open(path, type: mimeType.isEmpty ? null : mimeType);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 48,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircleAvatar(radius: 24, backgroundColor: primary, child: Icon(done ? icon : (downloading ? Icons.close_rounded : Icons.download_rounded), color: Colors.white)),
                  if (downloading) CircularProgressIndicator(value: progress, strokeWidth: 2.5, color: Colors.white),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name.isEmpty ? context.t('file') : name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    downloading ? '${formatFileSize(current.local.downloadedSize)} / ${formatFileSize(total)}' : formatFileSize(total),
                    style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// File state without triggering a download (unlike [fileProvider]).
final _fileStateProvider = StreamProvider.autoDispose.family<td.File, int>((ref, fileId) {
  return ref.watch(accountProvider).fileUpdates(fileId);
});

class _StickerView extends ConsumerWidget {
  const _StickerView({required this.sticker});

  final td.Sticker sticker;

  static const size = 160.0;

  Widget _fallback() {
    final thumb = sticker.thumbnail;
    if (thumb != null && thumb.format is! td.ThumbnailFormatTgs && thumb.format is! td.ThumbnailFormatWebm) {
      return TdImage(file: thumb.file, width: size, height: size, fit: BoxFit.contain);
    }
    return SizedBox.square(dimension: size, child: Center(child: Text(sticker.emoji, style: const TextStyle(fontSize: 96))));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final format = sticker.format;
    if (format is td.StickerFormatWebp) {
      return TdImage(file: sticker.sticker, width: size, height: size, fit: BoxFit.contain);
    }
    // WebM (VP9 with alpha) plays through ExoPlayer on Android; AVPlayer on iOS cannot decode it.
    if (format is td.StickerFormatWebm && !Platform.isAndroid) return _fallback();
    final file = ref.watch(fileProvider(sticker.sticker.id)).value ?? sticker.sticker;
    if (!file.local.isDownloadingCompleted || file.local.path.isEmpty) return _fallback();
    final path = file.local.path;
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: format is td.StickerFormatTgs
            ? Lottie.file(
                File(path),
                decoder: LottieComposition.decodeGZip,
                width: size,
                height: size,
                fit: BoxFit.contain,
                repeat: true,
                errorBuilder: (_, _, _) => _fallback(),
              )
            : LoopingVideo(path: path, fallback: _fallback()),
      ),
    );
  }
}

/// Silent looping video (WebM stickers, GIF previews).
class LoopingVideo extends StatefulWidget {
  const LoopingVideo({super.key, required this.path, required this.fallback});

  final String path;
  final Widget fallback;

  @override
  State<LoopingVideo> createState() => _LoopingVideoState();
}

class _LoopingVideoState extends State<LoopingVideo> {
  late final VideoPlayerController _controller = VideoPlayerController.file(File(widget.path));
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _controller.initialize();
      await _controller.setVolume(0);
      await _controller.setLooping(true);
      await _controller.play();
      if (mounted) setState(() => _ready = true);
    } on Object catch (error) {
      debugPrint('webm sticker failed: $error');
    }
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return widget.fallback;
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(width: _controller.value.size.width, height: _controller.value.size.height, child: VideoPlayer(_controller)),
    );
  }
}

class _LocationView extends StatelessWidget {
  const _LocationView({required this.latitude, required this.longitude, this.title, this.subtitle});

  final double latitude;
  final double longitude;
  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () => launchUrl(
        Uri.parse('https://maps.google.com/?q=$latitude,$longitude'),
        mode: LaunchMode.externalApplication,
      ),
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            Icon(Icons.location_on_rounded, color: primary, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title ?? context.t('location'), style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    subtitle ?? '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}',
                    style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveLocationView extends ConsumerWidget {
  const _LiveLocationView({required this.message, required this.location, required this.expiresIn});

  final td.Message message;
  final td.LiveLocation location;
  final int expiresIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final live = expiresIn > 0;
    final remaining = Duration(seconds: expiresIn);
    return ValueListenableBuilder<int>(
      valueListenable: LiveLocationService.instance.revision,
      builder: (context, _, _) {
        final sharing = message.isOutgoing && live && LiveLocationService.instance.isSharing(message.chatId, message.id);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _LocationView(
              latitude: location.location.latitude,
              longitude: location.location.longitude,
              title: s.t(live ? 'live_location' : 'live_location_ended'),
              subtitle: live
                  ? s.t('live_location_left', {'time': remaining.inHours > 0 ? '${remaining.inHours} h ${remaining.inMinutes % 60} min' : '${remaining.inMinutes} min'})
                  : null,
            ),
            if (sharing)
              TextButton.icon(
                onPressed: () => LiveLocationService.instance.stop(ref.read(accountProvider), message.chatId, message.id),
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(s.t('stop_sharing')),
              ),
          ],
        );
      },
    );
  }
}

class _ContactView extends ConsumerWidget {
  const _ContactView({required this.contact});

  final td.Contact contact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = '${contact.firstName} ${contact.lastName}'.trim();
    return InkWell(
      onTap: contact.userId == 0
          ? () => launchUrl(Uri(scheme: 'tel', path: contact.phoneNumber))
          : () async {
              final account = ref.read(accountProvider);
              final chat = await guard(context, () => account.openPrivateChat(contact.userId));
              if (chat != null && context.mounted) {
                Navigator.of(context).popUntil((route) => route.isFirst);
                openChatFromContent(context, chat.id);
              }
            },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Avatar(name: name, seed: contact.userId, size: 44),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(contact.phoneNumber, style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Hook set by the chat screen so content widgets can open chats without importing navigation.
void Function(BuildContext context, int chatId) openChatFromContent = (_, _) {};

class _CallView extends StatelessWidget {
  const _CallView({required this.isVideo, required this.duration, required this.outgoing});

  final bool isVideo;
  final int duration;
  final bool outgoing;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final missed = duration == 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(isVideo ? Icons.videocam_rounded : Icons.call_rounded, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.t(isVideo ? 'video_call' : 'voice_call'), style: const TextStyle(fontWeight: FontWeight.w600)),
            Row(children: [
              Icon(
                outgoing ? Icons.call_made_rounded : Icons.call_received_rounded,
                size: 14,
                color: missed ? Colors.redAccent : Colors.green,
              ),
              const SizedBox(width: 4),
              Text(
                missed ? s.t(outgoing ? 'call_cancelled' : 'call_missed') : formatDuration(Duration(seconds: duration)),
                style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
              ),
            ]),
          ],
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ voice notes

/// Single shared player so starting one voice note stops the previous one.
class VoicePlayback {
  VoicePlayback._();

  static final VoicePlayback instance = VoicePlayback._();
  final AudioPlayer player = AudioPlayer();
  final ValueNotifier<int?> currentFileId = ValueNotifier(null);
  final ValueNotifier<double> speed = ValueNotifier(1.0);

  Future<void> cycleSpeed() async {
    const speeds = [1.0, 1.5, 2.0];
    speed.value = speeds[(speeds.indexOf(speed.value) + 1) % speeds.length];
    await player.setSpeed(speed.value);
  }

  Future<void> toggle(int fileId, String path) async {
    if (currentFileId.value == fileId) {
      if (player.playing) {
        await player.pause();
      } else {
        await player.play();
      }
      return;
    }
    currentFileId.value = fileId;
    await player.setFilePath(path);
    unawaited(player.play());
  }
}

class VoiceNoteView extends ConsumerWidget {
  const VoiceNoteView({super.key, required this.message, required this.voiceNote});

  final td.Message message;
  final td.VoiceNote voiceNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final file = ref.watch(fileProvider(voiceNote.voice.id)).value ?? voiceNote.voice;
    final primary = Theme.of(context).colorScheme.primary;
    final samples = decodeWaveform(voiceNote.waveform);
    final playback = VoicePlayback.instance;
    final recognition = voiceNote.speechRecognitionResult;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<int?>(
          valueListenable: playback.currentFileId,
          builder: (context, currentId, _) {
            final isCurrent = currentId == voiceNote.voice.id;
            return StreamBuilder<PlayerState>(
              stream: playback.player.playerStateStream,
              builder: (context, snapshot) {
                final playing = isCurrent && (snapshot.data?.playing ?? false) &&
                    snapshot.data?.processingState != ProcessingState.completed;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () async {
                        final path = file.local.isDownloadingCompleted ? file.local.path : await account.downloadFile(file.id, priority: 32);
                        if (path != null) await playback.toggle(voiceNote.voice.id, path);
                      },
                      child: CircleAvatar(
                        radius: 22,
                        backgroundColor: primary,
                        child: file.local.isDownloadingActive
                            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 28),
                      ),
                    ),
                    const SizedBox(width: 10),
                    StreamBuilder<Duration>(
                      stream: isCurrent ? playback.player.positionStream : const Stream.empty(),
                      builder: (context, position) {
                        final total = Duration(seconds: voiceNote.duration);
                        final elapsed = position.data ?? Duration.zero;
                        final fraction = isCurrent && total.inMilliseconds > 0 ? elapsed.inMilliseconds / total.inMilliseconds : 0.0;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CustomPaint(
                              size: const Size(150, 26),
                              painter: WaveformPainter(samples: samples, progress: fraction.clamp(0, 1), color: primary),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              formatDuration(isCurrent && elapsed > Duration.zero ? elapsed : total),
                              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                            ),
                          ],
                        );
                      },
                    ),
                    if (isCurrent)
                      ValueListenableBuilder<double>(
                        valueListenable: playback.speed,
                        builder: (context, speed, _) => InkWell(
                          onTap: playback.cycleSpeed,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            margin: const EdgeInsets.only(left: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(border: Border.all(color: primary), borderRadius: BorderRadius.circular(8)),
                            child: Text('${speed == speed.roundToDouble() ? speed.toInt() : speed}x',
                                style: TextStyle(color: primary, fontSize: 11.5, fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: context.t('speech_to_text'),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.text_fields_rounded, color: primary, size: 20),
                      onPressed: recognition is td.SpeechRecognitionResultText
                          ? null
                          : () => guard(context, () => account.recognizeSpeech(message)),
                    ),
                  ],
                );
              },
            );
          },
        ),
        if (recognition is td.SpeechRecognitionResultText)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(recognition.text))
        else if (recognition is td.SpeechRecognitionResultPending)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${recognition.partialText}…', style: TextStyle(color: Theme.of(context).hintColor)),
          )
        else if (recognition is td.SpeechRecognitionResultError)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(errorTextFromCode(context, recognition.error.message), style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ),
      ],
    );
  }
}

String errorTextFromCode(BuildContext context, String code) {
  final s = context.s;
  final known = s.error(code);
  return known == s.t('err_GENERIC') ? code.replaceAll('_', ' ') : known;
}

class WaveformPainter extends CustomPainter {
  WaveformPainter({required this.samples, required this.progress, required this.color});

  final List<int> samples;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const barWidth = 2.5;
    const gap = 1.5;
    final count = (size.width / (barWidth + gap)).floor();
    final data = samples.isEmpty ? List<int>.filled(count, 4) : samples;
    final played = Paint()..color = color;
    final rest = Paint()..color = color.withValues(alpha: 0.35);
    for (var i = 0; i < count; i++) {
      final sample = data[(i * data.length / count).floor().clamp(0, data.length - 1)];
      final height = max(2.0, size.height * sample / 31);
      final x = i * (barWidth + gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, (size.height - height) / 2, barWidth, height),
        const Radius.circular(1.5),
      );
      canvas.drawRRect(rect, i / count <= progress ? played : rest);
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) => old.progress != progress || old.samples != samples || old.color != color;
}

// ------------------------------------------------------------------ polls

class PollView extends ConsumerWidget {
  const PollView({super.key, required this.message, required this.poll});

  final td.Message message;
  final td.Poll poll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final voted = poll.options.any((o) => o.isChosen);
    final showResults = voted || poll.isClosed;
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(poll.question.text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5)),
          const SizedBox(height: 2),
          Text(
            s.t(poll.isClosed ? 'poll_closed' : (poll.isAnonymous ? 'poll_anonymous' : 'poll_public')),
            style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < poll.options.length; i++)
            InkWell(
              onTap: poll.isClosed
                  ? null
                  : () {
                      final option = poll.options[i];
                      final chosen = [for (var j = 0; j < poll.options.length; j++) if (poll.options[j].isChosen) j];
                      final next = option.isChosen
                          ? chosen.where((j) => j != i).toList()
                          : (poll.allowsMultipleAnswers ? [...chosen, i] : [i]);
                      guard(context, () => account.vote(message, next));
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (showResults)
                          SizedBox(
                            width: 40,
                            child: Text('${poll.options[i].votePercentage}%', style: const TextStyle(fontWeight: FontWeight.w600)),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Icon(
                              poll.allowsMultipleAnswers ? Icons.check_box_outline_blank_rounded : Icons.radio_button_unchecked_rounded,
                              size: 20,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                        Expanded(child: Text(poll.options[i].text.text)),
                        if (poll.options[i].isChosen) Icon(Icons.check_circle_rounded, size: 18, color: primary),
                      ],
                    ),
                    if (showResults)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: poll.options[i].votePercentage / 100,
                            minHeight: 4,
                            color: primary,
                            backgroundColor: primary.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 4),
          Text(s.count('votes', poll.totalVoterCount), style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
        ],
      ),
    );
  }
}

extension ChatColorsFor on BuildContext {
  Color metaColor(bool outgoing) => outgoing ? chatColors.outgoingMeta : chatColors.incomingMeta;
}

// ------------------------------------------------------------------ invoices

String formatInvoiceAmount(int amount, String currency) {
  if (currency == 'XTR') return '$amount ⭐';
  // Telegram amounts are in the smallest currency unit; most currencies use two decimals.
  const zeroDecimal = {'JPY', 'KRW', 'UZS', 'VND', 'CLP', 'ISK', 'UGX', 'XAF', 'XOF'};
  final value = zeroDecimal.contains(currency) ? amount.toString() : (amount / 100).toStringAsFixed(2);
  return '$value $currency';
}

class InvoiceView extends ConsumerWidget {
  const InvoiceView({super.key, required this.message});

  final td.Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invoice = message.content as td.MessageInvoice;
    final info = invoice.productInfo;
    final photo = info.photo;
    final size = photo == null ? null : bestPhotoSize(photo, target: 600);
    final hasBuyButton = switch (message.replyMarkup) {
      td.ReplyMarkupInlineKeyboard(:final rows) => rows.expand((r) => r).any((b) => b.type is td.InlineKeyboardButtonTypeBuy),
      _ => false,
    };
    final paid = invoice.receiptMessageId != 0;
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (size != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: TdImage(file: size.photo, minithumbnail: photo!.minithumbnail, width: 260, height: 160),
            ),
          const SizedBox(height: 6),
          Text(info.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5)),
          if (info.description.text.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(info.description.text)),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                formatInvoiceAmount(invoice.totalAmount, invoice.currency),
                style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary),
              ),
              if (invoice.isTest) Text('  ${context.t('test_invoice')}', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            ],
          ),
          if (!hasBuyButton && !paid)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: FilledButton.tonal(
                onPressed: () => payInvoice(context, ref, message),
                child: Text(context.t('pay')),
              ),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ albums

/// Photos and videos of one media album laid out as a grid (2 side by side, 3 = 1 + 2, 4 = 2 x 2, more in rows of 3).
class AlbumGrid extends StatelessWidget {
  const AlbumGrid({super.key, required this.messages, required this.maxWidth});

  /// Oldest first.
  final List<td.Message> messages;
  final double maxWidth;

  static const _gap = 2.0;

  List<List<td.Message>> _rows() {
    final n = messages.length;
    if (n <= 2) return [messages];
    if (n == 3) return [messages.sublist(0, 1), messages.sublist(1)];
    if (n == 4) return [messages.sublist(0, 2), messages.sublist(2)];
    final rows = <List<td.Message>>[];
    var i = 0;
    // Rows of 3, but never leave a single item on the last row.
    while (i < n) {
      final remaining = n - i;
      final take = remaining == 4 ? 2 : min(3, remaining);
      rows.add(messages.sublist(i, i + take));
      i += take;
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final media = messages.where((m) => m.content is td.MessagePhoto || m.content is td.MessageVideo).toList();
    if (media.length != messages.length) {
      // Document / audio albums are a plain vertical list.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final m in messages) Padding(padding: const EdgeInsets.only(bottom: 4), child: MessageMedia(message: m, maxWidth: maxWidth))],
      );
    }
    final rows = _rows();
    return SizedBox(
      width: maxWidth,
      child: Column(
        children: [
          for (var r = 0; r < rows.length; r++)
            Padding(
              padding: EdgeInsets.only(bottom: r == rows.length - 1 ? 0 : _gap),
              child: Row(
                children: [
                  for (var c = 0; c < rows[r].length; c++) ...[
                    if (c > 0) const SizedBox(width: _gap),
                    Expanded(
                      child: SizedBox(
                        // Square cells; a lone wide cell (top of a 3-item album) is shorter.
                        height: rows[r].length == 1 ? maxWidth * 0.66 : maxWidth / rows[r].length,
                        child: _AlbumTile(message: rows[r][c]),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({required this.message});

  final td.Message message;

  @override
  Widget build(BuildContext context) {
    switch (message.content) {
      case td.MessagePhoto(:final photo):
        final size = bestPhotoSize(photo, target: 600);
        if (size == null) return const ColoredBox(color: Colors.black12);
        return GestureDetector(
          onTap: () => openPhotoViewer(context, bestPhotoSize(photo, target: 2560)!.photo, photo.minithumbnail),
          child: TdImage(file: size.photo, minithumbnail: photo.minithumbnail, fit: BoxFit.cover),
        );
      case td.MessageVideo(:final video):
        final thumb = video.thumbnail;
        return GestureDetector(
          onTap: () => openVideoPlayer(context, video.video),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (thumb != null && thumb.format is! td.ThumbnailFormatMpeg4)
                TdImage(file: thumb.file, minithumbnail: video.minithumbnail, fit: BoxFit.cover)
              else
                const ColoredBox(color: Colors.black26),
              const Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 40)),
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                  child: Text(formatDuration(Duration(seconds: video.duration)), style: const TextStyle(color: Colors.white, fontSize: 11.5)),
                ),
              ),
            ],
          ),
        );
      default:
        return const ColoredBox(color: Colors.black12);
    }
  }
}
