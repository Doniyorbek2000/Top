import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:video_player/video_player.dart';

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../chat/message_content.dart';

bool _hasUnread(td.ChatActiveStories stories) => stories.stories.any((s) => s.storyId > stories.maxReadStoryId);

/// Horizontal row of chats with active stories (shown above the main chat list).
class StoriesBar extends ConsumerWidget {
  const StoriesBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(storyFeedProvider);
    if (feed.isEmpty) return const SizedBox.shrink();
    final account = ref.watch(accountProvider);
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 96,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        itemCount: feed.length,
        itemBuilder: (context, index) {
          final entry = feed[index];
          final chat = account.chats[entry.chatId];
          final unread = _hasUnread(entry);
          final isMe = chat != null && account.isSavedMessages(chat);
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.of(context).push(PageRouteBuilder<void>(
              opaque: true,
              pageBuilder: (_, _, _) => StoryViewer(feed: feed, initialIndex: index),
              transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
            )),
            child: SizedBox(
              width: 72,
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(2.5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: unread ? primary : Theme.of(context).dividerColor, width: 2.2),
                    ),
                    child: ChatAvatar(chatId: entry.chatId, size: 50, showOnline: false),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isMe ? context.t('my_story') : (chat?.title ?? ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: unread ? FontWeight.w600 : FontWeight.w400),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Full-screen story player: tap right/left for next/previous, hold to pause, swipe down to close.
class StoryViewer extends ConsumerStatefulWidget {
  const StoryViewer({super.key, required this.feed, required this.initialIndex});

  final List<td.ChatActiveStories> feed;
  final int initialIndex;

  @override
  ConsumerState<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends ConsumerState<StoryViewer> with SingleTickerProviderStateMixin {
  late final TelegramAccount _account = ref.read(accountProvider);
  late int _chatIndex = widget.initialIndex;
  int _storyIndex = 0;
  td.Story? _story;
  String? _error;
  VideoPlayerController? _video;
  late final AnimationController _progress = AnimationController(vsync: this)..addStatusListener(_onProgressStatus);
  int? _openedChatId;
  int? _openedStoryId;

  static const _photoDuration = Duration(seconds: 6);

  td.ChatActiveStories get _entry => widget.feed[_chatIndex];

  @override
  void initState() {
    super.initState();
    // Start at the first unread story of the chat, like Telegram.
    final firstUnread = _entry.stories.indexWhere((s) => s.storyId > _entry.maxReadStoryId);
    _storyIndex = firstUnread < 0 ? 0 : firstUnread;
    unawaited(_load());
  }

  @override
  void dispose() {
    _closeCurrent();
    _progress.dispose();
    unawaited(_video?.dispose());
    super.dispose();
  }

  void _onProgressStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _next();
  }

  void _closeCurrent() {
    final chatId = _openedChatId;
    final storyId = _openedStoryId;
    if (chatId != null && storyId != null) {
      unawaited(_account.send<td.Ok>(td.CloseStory(storyPosterChatId: chatId, storyId: storyId)).catchError((Object _) => const td.Ok()));
    }
    _openedChatId = null;
    _openedStoryId = null;
  }

  Future<void> _load() async {
    _closeCurrent();
    _progress.stop();
    final oldVideo = _video;
    setState(() {
      _story = null;
      _error = null;
      _video = null;
    });
    unawaited(oldVideo?.dispose());
    final info = _entry.stories[_storyIndex];
    final chatId = _entry.chatId;
    try {
      final story = await _account.send<td.Story>(td.GetStory(storyPosterChatId: chatId, storyId: info.storyId, onlyLocal: false));
      if (!mounted || chatId != _entry.chatId || info.storyId != _entry.stories[_storyIndex].storyId) return;
      // openStory marks the story as viewed; ghost mode keeps views private.
      if (!ref.read(settingsProvider).ghostMode) {
        unawaited(_account.send<td.Ok>(td.OpenStory(storyPosterChatId: chatId, storyId: story.id)).catchError((Object _) => const td.Ok()));
        _openedChatId = chatId;
        _openedStoryId = story.id;
      }
      setState(() => _story = story);
      await _start(story);
    } on TdException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _start(td.Story story) async {
    switch (story.content) {
      case td.StoryContentVideo(:final video):
        final path = await _account.downloadFile(video.video.id, priority: 32);
        if (!mounted || path == null || _story?.id != story.id) return;
        final controller = VideoPlayerController.file(File(path));
        try {
          await controller.initialize();
        } on Object catch (error) {
          await controller.dispose();
          if (mounted) setState(() => _error = '$error');
          return;
        }
        if (!mounted || _story?.id != story.id) {
          await controller.dispose();
          return;
        }
        setState(() => _video = controller);
        _progress.duration = controller.value.duration > Duration.zero ? controller.value.duration : _photoDuration;
        await controller.play();
        _progress.forward(from: 0);
      case td.StoryContentPhoto(:final photo):
        final size = bestPhotoSize(photo, target: 1280);
        if (size != null) await _account.downloadFile(size.photo.id, priority: 32);
        if (!mounted || _story?.id != story.id) return;
        _progress.duration = _photoDuration;
        _progress.forward(from: 0);
      default:
        _progress.duration = _photoDuration;
        _progress.forward(from: 0);
    }
  }

  void _next() {
    if (_storyIndex + 1 < _entry.stories.length) {
      _storyIndex++;
    } else if (_chatIndex + 1 < widget.feed.length) {
      _chatIndex++;
      _storyIndex = 0;
    } else {
      Navigator.of(context).maybePop();
      return;
    }
    unawaited(_load());
  }

  void _previous() {
    if (_storyIndex > 0) {
      _storyIndex--;
    } else if (_chatIndex > 0) {
      _chatIndex--;
      _storyIndex = widget.feed[_chatIndex].stories.length - 1;
    } else {
      _progress.forward(from: 0);
      unawaited(_video?.seekTo(Duration.zero));
      return;
    }
    unawaited(_load());
  }

  void _pause() {
    _progress.stop();
    unawaited(_video?.pause());
  }

  void _resume() {
    if (_story == null) return;
    _progress.forward();
    unawaited(_video?.play());
  }

  Widget _content() {
    final story = _story;
    if (_error != null) {
      return Center(child: Text(errorTextFromCode(context, _error!), style: const TextStyle(color: Colors.white70)));
    }
    if (story == null) return const Center(child: CircularProgressIndicator(color: Colors.white));
    switch (story.content) {
      case td.StoryContentPhoto(:final photo):
        final size = bestPhotoSize(photo, target: 1280);
        if (size == null) return const SizedBox.shrink();
        return TdImage(file: size.photo, minithumbnail: photo.minithumbnail, fit: BoxFit.contain);
      case td.StoryContentVideo(:final video):
        final controller = _video;
        if (controller == null) {
          final thumb = video.thumbnail;
          return Stack(
            alignment: Alignment.center,
            fit: StackFit.expand,
            children: [
              if (thumb != null && thumb.format is! td.ThumbnailFormatMpeg4)
                TdImage(file: thumb.file, minithumbnail: video.minithumbnail, fit: BoxFit.contain),
              const Center(child: CircularProgressIndicator(color: Colors.white)),
            ],
          );
        }
        return Center(child: AspectRatio(aspectRatio: controller.value.aspectRatio, child: VideoPlayer(controller)));
      default:
        return Center(child: Text(context.t('story_unsupported'), style: const TextStyle(color: Colors.white70)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    final chat = _account.chats[entry.chatId];
    final story = _story;
    final s = context.s;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (details) {
          final width = MediaQuery.sizeOf(context).width;
          if (details.globalPosition.dx < width / 3) {
            _previous();
          } else {
            _next();
          }
        },
        onLongPressStart: (_) => _pause(),
        onLongPressEnd: (_) => _resume(),
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) > 300) Navigator.of(context).maybePop();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _content(),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: Row(
                      children: [
                        for (var i = 0; i < entry.stories.length; i++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: AnimatedBuilder(
                                animation: _progress,
                                builder: (context, _) => LinearProgressIndicator(
                                  value: i < _storyIndex ? 1 : (i == _storyIndex ? _progress.value : 0),
                                  minHeight: 2.5,
                                  color: Colors.white,
                                  backgroundColor: Colors.white30,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: ChatAvatar(chatId: entry.chatId, size: 38, showOnline: false),
                    title: Text(chat?.title ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    subtitle: story == null
                        ? null
                        : Text(formatChatTime(story.date, s.locale), style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                    trailing: IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  const Spacer(),
                  if (story != null && story.caption.text.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87]),
                      ),
                      child: FormattedTextView(text: story.caption, style: const TextStyle(color: Colors.white, fontSize: 15)),
                    ),
                  if (story?.interactionInfo case final td.StoryInteractionInfo interaction when story!.canGetInteractions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.visibility_rounded, color: Colors.white70, size: 18),
                          const SizedBox(width: 6),
                          Text(formatCount(interaction.viewCount), style: const TextStyle(color: Colors.white70)),
                        ],
                      ),
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
