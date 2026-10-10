import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// Chat-specific colors that Material's ColorScheme does not cover.
@immutable
class ChatColors extends ThemeExtension<ChatColors> {
  const ChatColors({
    required this.outgoingBubble,
    required this.incomingBubble,
    required this.outgoingText,
    required this.incomingText,
    required this.outgoingMeta,
    required this.incomingMeta,
    required this.chatBackground,
    required this.online,
    required this.unreadBadge,
    required this.mutedBadge,
  });

  final Color outgoingBubble;
  final Color incomingBubble;
  final Color outgoingText;
  final Color incomingText;
  final Color outgoingMeta;
  final Color incomingMeta;
  final Color chatBackground;
  final Color online;
  final Color unreadBadge;
  final Color mutedBadge;

  @override
  ChatColors copyWith() => this;

  @override
  ChatColors lerp(ThemeExtension<ChatColors>? other, double t) {
    if (other is! ChatColors) return this;
    return ChatColors(
      outgoingBubble: Color.lerp(outgoingBubble, other.outgoingBubble, t)!,
      incomingBubble: Color.lerp(incomingBubble, other.incomingBubble, t)!,
      outgoingText: Color.lerp(outgoingText, other.outgoingText, t)!,
      incomingText: Color.lerp(incomingText, other.incomingText, t)!,
      outgoingMeta: Color.lerp(outgoingMeta, other.outgoingMeta, t)!,
      incomingMeta: Color.lerp(incomingMeta, other.incomingMeta, t)!,
      chatBackground: Color.lerp(chatBackground, other.chatBackground, t)!,
      online: Color.lerp(online, other.online, t)!,
      unreadBadge: Color.lerp(unreadBadge, other.unreadBadge, t)!,
      mutedBadge: Color.lerp(mutedBadge, other.mutedBadge, t)!,
    );
  }
}

extension ChatColorsX on BuildContext {
  ChatColors get chatColors => Theme.of(this).extension<ChatColors>()!;
}

ThemeData buildTheme(Brightness brightness, Color accent) {
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness);
  final isDark = brightness == Brightness.dark;
  final surface = isDark ? const Color(0xFF151A21) : Colors.white;
  final chatColors = ChatColors(
    outgoingBubble: isDark ? Color.lerp(accent, Colors.black, 0.35)! : Color.lerp(accent, Colors.white, 0.82)!,
    incomingBubble: isDark ? const Color(0xFF222A35) : Colors.white,
    outgoingText: isDark ? Colors.white : const Color(0xFF0E1621),
    incomingText: isDark ? Colors.white : const Color(0xFF0E1621),
    outgoingMeta: isDark ? Colors.white70 : Color.lerp(accent, Colors.black, 0.25)!,
    incomingMeta: isDark ? Colors.white54 : const Color(0xFF8A96A3),
    chatBackground: isDark ? const Color(0xFF0E1218) : Color.lerp(accent, const Color(0xFFDDE6EE), 0.88)!,
    online: const Color(0xFF2EBD59),
    unreadBadge: accent,
    mutedBadge: isDark ? const Color(0xFF4A5563) : const Color(0xFFB0BAC5),
  );
  // Base typography so custom text styles below keep the platform font family.
  final typography = Typography.material2021(platform: defaultTargetPlatform, colorScheme: scheme);
  final textTheme = (isDark ? typography.white : typography.black);
  return ThemeData(
    useMaterial3: true,
    textTheme: textTheme,
    colorScheme: scheme.copyWith(surface: surface, primary: accent),
    scaffoldBackgroundColor: surface,
    extensions: [chatColors],
    appBarTheme: AppBarTheme(
      backgroundColor: isDark ? const Color(0xFF1B222C) : accent,
      foregroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge?.copyWith(fontSize: 19, fontWeight: FontWeight.w600, color: Colors.white),
      iconTheme: const IconThemeData(color: Colors.white),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: accent,
      foregroundColor: Colors.white,
      shape: const CircleBorder(),
    ),
    dividerTheme: DividerThemeData(
      color: isDark ? Colors.white10 : Colors.black12,
      thickness: 0.5,
      space: 0.5,
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}
