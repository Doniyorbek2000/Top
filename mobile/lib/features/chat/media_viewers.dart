import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:video_player/video_player.dart';

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

void openPhotoViewer(BuildContext context, td.File file, td.Minithumbnail? minithumbnail) {
  Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black,
    pageBuilder: (_, _, _) => _PhotoViewerScreen(file: file, minithumbnail: minithumbnail),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ));
}

void openVideoPlayer(BuildContext context, td.File file, {bool loop = false}) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _VideoPlayerScreen(file: file, loop: loop)));
}

class _PhotoViewerScreen extends ConsumerWidget {
  const _PhotoViewerScreen({required this.file, required this.minithumbnail});

  final td.File file;
  final td.Minithumbnail? minithumbnail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(fileProvider(file.id)).value ?? file;
    final ready = current.local.isDownloadingCompleted;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black38,
        actions: [
          if (ready)
            IconButton(
              icon: const Icon(Icons.share_rounded),
              onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(current.local.path)])),
            ),
        ],
      ),
      body: GestureDetector(
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0).abs() > 800) Navigator.pop(context);
        },
        child: ready
            ? PhotoView(
                imageProvider: FileImage(File(current.local.path)),
                minScale: PhotoViewComputedScale.contained,
                maxScale: PhotoViewComputedScale.covered * 4,
                heroAttributes: PhotoViewHeroAttributes(tag: 'photo_${file.id}'),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  TdImage(file: file, minithumbnail: minithumbnail, fit: BoxFit.contain),
                  const Center(child: CircularProgressIndicator(color: Colors.white)),
                ],
              ),
      ),
    );
  }
}

class _VideoPlayerScreen extends ConsumerStatefulWidget {
  const _VideoPlayerScreen({required this.file, required this.loop});

  final td.File file;
  final bool loop;

  @override
  ConsumerState<_VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<_VideoPlayerScreen> {
  VideoPlayerController? _controller;
  bool _initializing = false;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _start(String path) async {
    if (_initializing || _controller != null) return;
    _initializing = true;
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      await controller.setLooping(widget.loop);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      unawaited(controller.play());
    } on Object catch (error) {
      await controller.dispose();
      if (mounted) showToast(context, context.t('err_GENERIC'));
      debugPrint('video init failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(fileProvider(widget.file.id)).value ?? widget.file;
    if (current.local.isDownloadingCompleted && _controller == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start(current.local.path));
    }
    final controller = _controller;
    final total = current.size == 0 ? current.expectedSize : current.size;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        actions: [
          if (controller != null)
            TextButton(
              onPressed: () {
                const speeds = [1.0, 1.25, 1.5, 2.0, 0.5];
                final next = speeds[(speeds.indexOf(controller.value.playbackSpeed) + 1) % speeds.length];
                unawaited(controller.setPlaybackSpeed(next));
                setState(() {});
              },
              child: Text('${controller.value.playbackSpeed}x', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          if (current.local.isDownloadingCompleted)
            IconButton(
              icon: const Icon(Icons.share_rounded),
              onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(current.local.path)])),
            ),
        ],
      ),
      body: Center(
        child: controller == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    color: Colors.white,
                    value: total > 0 ? current.local.downloadedSize / total : null,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${formatFileSize(current.local.downloadedSize)} / ${formatFileSize(total)}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              )
            : GestureDetector(
                onTap: () => setState(() => controller.value.isPlaying ? controller.pause() : controller.play()),
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    AspectRatio(aspectRatio: controller.value.aspectRatio, child: VideoPlayer(controller)),
                    VideoProgressIndicator(controller, allowScrubbing: true, padding: const EdgeInsets.all(12)),
                    if (!controller.value.isPlaying)
                      const Positioned.fill(
                        child: Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white70, size: 72)),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
