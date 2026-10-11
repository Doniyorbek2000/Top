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
  // Dialogs, sheets and menus sit one step above the page.
  final elevated = isDark ? const Color(0xFF1C232D) : Colors.white;
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
    // Neutral outline: text fields declaring InputBorder.none (composer, search) must stay borderless,
    // so field borders are styled through the scheme rather than a theme-level enabledBorder.
    colorScheme: scheme.copyWith(surface: surface, primary: accent, outline: isDark ? Colors.white24 : const Color(0xFFCBD3DB)),
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
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      iconColor: isDark ? const Color(0xFF8D99A6) : const Color(0xFF707A86),
      minLeadingWidth: 28,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: isDark ? const Color(0xFF2A3340) : const Color(0xFF262D36),
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white, fontSize: 14.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
    ),
    // Untinted surfaces everywhere: Material 3 tints dialogs, sheets and the drawer with the seed
    // color, which reads as lavender next to the white/graphite chat UI.
    drawerTheme: DrawerThemeData(backgroundColor: surface, surfaceTintColor: Colors.transparent, width: 300),
    dialogTheme: DialogThemeData(
      backgroundColor: elevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: textTheme.titleLarge?.copyWith(fontSize: 19, fontWeight: FontWeight.w600),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: elevated,
      modalBackgroundColor: elevated,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: isDark ? Colors.white24 : Colors.black26,
      dragHandleSize: const Size(36, 4),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: elevated,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: textTheme.bodyLarge?.copyWith(fontSize: 15.5),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(elevated),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      ),
    ),
    cardTheme: CardThemeData(
      color: elevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: textTheme.labelLarge?.copyWith(fontSize: 15.5, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: isDark ? Colors.white24 : Colors.black12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(textStyle: textTheme.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? Colors.white : (isDark ? Colors.white70 : Colors.white)),
      trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? accent : (isDark ? Colors.white24 : const Color(0xFFD5DBE1))),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? accent : null),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? accent : null)),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent, linearTrackColor: accent.withValues(alpha: 0.15)),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent,
      selectionColor: accent.withValues(alpha: 0.3),
      selectionHandleColor: accent,
    ),
    tabBarTheme: TabBarThemeData(
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: textTheme.titleSmall?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
      unselectedLabelStyle: textTheme.titleSmall?.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
    ),
    badgeTheme: BadgeThemeData(backgroundColor: accent, textColor: Colors.white),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: isDark ? const Color(0xFF2A3340) : const Color(0xE6262D36), borderRadius: BorderRadius.circular(8)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}
