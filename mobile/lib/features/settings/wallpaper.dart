import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../widgets/chat_pattern.dart';

const _gradients = <List<Color>>[
  [Color(0xFFDCE8F5), Color(0xFFB7D3F0)],
  [Color(0xFFE8F5E9), Color(0xFFB9E4C9)],
  [Color(0xFFFFF3E0), Color(0xFFFFCC80)],
  [Color(0xFFF3E5F5), Color(0xFFD1C4E9)],
  [Color(0xFF1F2A44), Color(0xFF3A4F7A)],
  [Color(0xFF0F2027), Color(0xFF2C5364)],
];

const _solids = <Color>[
  Color(0xFFE6EBEE),
  Color(0xFFD8E4D2),
  Color(0xFFF2E6D9),
  Color(0xFFE3DCF2),
  Color(0xFF1C2733),
  Color(0xFF101418),
];

/// Chat background chosen in Appearance → Chat background.
class ChatBackground extends ConsumerWidget {
  const ChatBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallpaper = ref.watch(settingsProvider.select((s) => s.wallpaper));
    final fallback = context.chatColors.chatBackground;
    BoxDecoration decoration;
    if (wallpaper.startsWith('color:')) {
      decoration = BoxDecoration(color: Color(int.tryParse(wallpaper.substring(6), radix: 16) ?? fallback.toARGB32()));
    } else if (wallpaper.startsWith('gradient:')) {
      final index = (int.tryParse(wallpaper.substring(9)) ?? 0).clamp(0, _gradients.length - 1);
      decoration = BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: _gradients[index]));
    } else if (wallpaper.startsWith('file:') && File(wallpaper.substring(5)).existsSync()) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      decoration = BoxDecoration(
        color: fallback,
        image: DecorationImage(
          image: FileImage(File(wallpaper.substring(5))),
          fit: BoxFit.cover,
          // Dim photo backgrounds in dark mode so bubbles stay readable.
          colorFilter: dark ? const ColorFilter.mode(Colors.black45, BlendMode.darken) : null,
        ),
      );
    } else {
      decoration = BoxDecoration(color: fallback);
    }
    final pattern = ref.watch(settingsProvider.select((s) => s.wallpaperPattern)) && !wallpaper.startsWith('file:');
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: decoration,
      child: pattern
          ? Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: CustomPaint(painter: ChatPatternPainter(color: dark ? Colors.white.withValues(alpha: 0.035) : Colors.black.withValues(alpha: 0.055))),
                ),
                child,
              ],
            )
          : child,
    );
  }
}

class WallpaperScreen extends ConsumerWidget {
  const WallpaperScreen({super.key});

  Future<void> _pickPhoto(BuildContext context, WidgetRef ref) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 2000);
    if (picked == null) return;
    final dir = await getApplicationSupportDirectory();
    final target = File('${dir.path}${Platform.pathSeparator}wallpaper_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await File(picked.path).copy(target.path);
    final previous = ref.read(settingsProvider).wallpaper;
    ref.read(settingsProvider.notifier).setWallpaper('file:${target.path}');
    if (previous.startsWith('file:')) {
      final old = File(previous.substring(5));
      if (await old.exists()) await old.delete();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final current = ref.watch(settingsProvider.select((st) => st.wallpaper));
    final notifier = ref.read(settingsProvider.notifier);
    final primary = Theme.of(context).colorScheme.primary;
    Widget swatch(String value, Decoration decoration, {Widget? child}) => GestureDetector(
          onTap: () => notifier.setWallpaper(value),
          child: Container(
            decoration: decoration,
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: current == value ? primary : Colors.transparent, width: 3),
            ),
            child: child,
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(s.t('chat_background'))),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          SizedBox(
            height: 220,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: ChatBackground(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(color: context.chatColors.incomingBubble, borderRadius: BorderRadius.circular(16)),
                    child: Text(s.t('wallpaper_preview'), style: TextStyle(color: context.chatColors.incomingText)),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickPhoto(context, ref),
                  icon: const Icon(Icons.photo_library_rounded),
                  label: Text(s.t('wallpaper_from_gallery')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => notifier.setWallpaper(''),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: Text(s.t('wallpaper_reset')),
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.t('wallpaper_pattern')),
            value: ref.watch(settingsProvider.select((st) => st.wallpaperPattern)),
            onChanged: notifier.setWallpaperPattern,
          ),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.7,
            children: [
              for (var i = 0; i < _gradients.length; i++)
                swatch(
                  'gradient:$i',
                  BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: _gradients[i]),
                  ),
                ),
              for (final color in _solids)
                swatch(
                  'color:${color.toARGB32().toRadixString(16).padLeft(8, '0')}',
                  BoxDecoration(borderRadius: BorderRadius.circular(12), color: color),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
