import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../core/formatters.dart';
import '../core/tdlib/td_client.dart';
import '../core/theme.dart';
import '../l10n/strings.dart';
import '../state/providers.dart';

const _avatarGradients = <List<Color>>[
  [Color(0xFFFF885E), Color(0xFFFF516A)],
  [Color(0xFFFFCD6A), Color(0xFFFFA85C)],
  [Color(0xFF82B1FF), Color(0xFF665FFF)],
  [Color(0xFFA0DE7E), Color(0xFF54CB68)],
  [Color(0xFF53EDD6), Color(0xFF28C9B7)],
  [Color(0xFF72D5FD), Color(0xFF2A9EF1)],
  [Color(0xFFE0A2F3), Color(0xFFD669ED)],
];

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  final first = parts.first.characters.first;
  final second = parts.length > 1 ? parts[1].characters.first : '';
  return (first + second).toUpperCase();
}

/// Shows a TDLib file as an image once downloaded, with the inline minithumbnail as placeholder.
class TdImage extends ConsumerWidget {
  const TdImage({
    super.key,
    required this.file,
    this.minithumbnail,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.download = true,
  });

  /// False shows only what is already cached (data-saving mode); the caller offers a download button.
  final bool download;
  final td.File file;
  final td.Minithumbnail? minithumbnail;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = (download ? ref.watch(fileProvider(file.id)).value : ref.watch(fileStateProvider(file.id)).value) ?? file;
    final fallback = minithumbnail != null
        ? Image.memory(
            base64Decode(minithumbnail!.data),
            fit: fit,
            width: width,
            height: height,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          )
        : (placeholder ?? SizedBox(width: width, height: height));
    if (!current.local.isDownloadingCompleted || current.local.path.isEmpty) return fallback;
    return Image.file(
      File(current.local.path),
      fit: fit,
      width: width,
      height: height,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    required this.seed,
    this.photo,
    this.minithumbnail,
    this.size = 48,
    this.online = false,
    this.icon,
  });

  final String name;
  final int seed;
  final td.File? photo;
  final td.Minithumbnail? minithumbnail;
  final double size;
  final bool online;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = _avatarGradients[seed.abs() % _avatarGradients.length];
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: colors, begin: Alignment.topCenter, end: Alignment.bottomCenter),
      ),
      child: Center(
        child: icon != null
            ? Icon(icon, color: Colors.white, size: size * 0.5)
            : Text(
                initialsOf(name),
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: size * 0.38),
              ),
      ),
    );
    Widget avatar = SizedBox.square(
      dimension: size,
      child: photo == null || icon != null
          ? placeholder
          : ClipOval(
              child: TdImage(
                file: photo!,
                minithumbnail: minithumbnail,
                width: size,
                height: size,
                placeholder: placeholder,
              ),
            ),
    );
    if (online) {
      final dot = size * 0.28;
      avatar = Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: context.chatColors.online,
                shape: BoxShape.circle,
                border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: size * 0.05),
              ),
            ),
          ),
        ],
      );
    }
    return avatar;
  }
}

/// Avatar for a chat, resolving Saved Messages, user presence and photos.
class ChatAvatar extends ConsumerWidget {
  const ChatAvatar({super.key, required this.chatId, this.size = 48, this.showOnline = true});

  final int chatId;
  final double size;
  final bool showOnline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider(chatId));
    final account = ref.watch(accountProvider);
    if (chat == null) return SizedBox.square(dimension: size);
    final saved = account.isSavedMessages(chat);
    final user = account.privateUser(chat);
    return Avatar(
      name: chat.title,
      seed: user?.id ?? chat.id,
      photo: chat.photo?.small,
      minithumbnail: chat.photo?.minithumbnail,
      size: size,
      online: showOnline && !saved && isOnline(user) && !account.isBot(user),
      icon: saved ? Icons.bookmark_rounded : null,
    );
  }
}

class UserAvatar extends ConsumerWidget {
  const UserAvatar({super.key, required this.userId, this.size = 48, this.showOnline = true});

  final int userId;
  final double size;
  final bool showOnline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProvider(userId));
    if (user == null) return SizedBox.square(dimension: size);
    return Avatar(
      name: '${user.firstName} ${user.lastName}',
      seed: user.id,
      photo: user.profilePhoto?.small,
      minithumbnail: user.profilePhoto?.minithumbnail,
      size: size,
      online: showOnline && isOnline(user),
    );
  }
}

String errorText(BuildContext context, Object error) {
  final s = Strings.of(context);
  if (error is TdException) {
    if (error.isFloodWait) return s.t('err_FLOOD_WAIT');
    final known = s.error(error.message);
    if (known != s.t('err_GENERIC')) return known;
    return error.message.replaceAll('_', ' ');
  }
  return s.t('err_GENERIC');
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(errorText(context, error))));
}

void showToast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  String? message,
  String? confirmLabel,
  bool destructive = false,
}) async {
  final s = Strings.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('cancel'))),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          style: destructive ? TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error) : null,
          child: Text(confirmLabel ?? s.t('ok')),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Runs a TDLib action and reports failures as a snackbar. Returns null on failure.
Future<T?> guard<T>(BuildContext context, Future<T> Function() action) async {
  try {
    return await action();
  } on TdException catch (error) {
    if (context.mounted) showError(context, error);
    return null;
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(
          text,
          style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600, fontSize: 14),
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.subtitle, this.action});

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, color: theme.colorScheme.primary.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(subtitle!,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor), textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// Colored rounded-square icon used in settings lists (Telegram/iOS style).
class TileIcon extends StatelessWidget {
  const TileIcon(this.icon, this.color, {super.key});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color.lerp(color, Colors.white, 0.12)!, color],
          ),
        ),
        child: Icon(icon, size: 19, color: Colors.white),
      );
}
