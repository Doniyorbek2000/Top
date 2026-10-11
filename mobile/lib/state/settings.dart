import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Brand accents users can pick from (Plus Messenger style theming).
const accentPalette = <Color>[
  Color(0xFF0A6CFF), // Sado blue (logo)
  Color(0xFF0FA3B1), // teal
  Color(0xFF7C4DFF), // violet
  Color(0xFFE5486A), // rose
  Color(0xFFFF8A1F), // orange
  Color(0xFF2EAD5B), // green
  Color(0xFF5A6B7F), // graphite
];

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.accentIndex = 0,
    this.localeCode = 'uz',
    this.textScale = 1.0,
    this.ghostMode = false,
    this.sendByEnter = false,
    this.quickReaction = '👍',
    this.translateTo = 'uz',
    this.notificationsEnabled = true,
    this.messagePreview = true,
    this.bubbleRadius = 18,
    this.showTranslateButton = true,
    this.chatTypeTabs = false,
    this.keepMediaDays = 0,
    this.autoDownloadPhotos = true,
    this.autoplayGifs = true,
    this.hiddenChatIds = const {},
    this.wallpaper = '',
    this.wallpaperPattern = true,
  });

  final ThemeMode themeMode;
  final int accentIndex;
  final String localeCode;
  final double textScale;

  /// Ghost mode: do not send read receipts or typing indicators.
  final bool ghostMode;
  final bool sendByEnter;
  final String quickReaction;
  final String translateTo;
  final bool notificationsEnabled;
  final bool messagePreview;
  final double bubbleRadius;
  final bool showTranslateButton;

  /// Extra tabs filtering chats by type (users, groups, channels, bots, unread).
  final bool chatTypeTabs;

  /// Cached media not opened for this many days is deleted (0 = keep forever).
  final int keepMediaDays;
  final bool autoDownloadPhotos;
  final bool autoplayGifs;

  /// Chats hidden from the chat lists (shown only in the passcode-protected "Hidden chats" screen).
  final Set<int> hiddenChatIds;

  /// Chat background: '' default, 'color:AARRGGBB', 'gradient:N' or 'file:/path'.
  final String wallpaper;
  final bool wallpaperPattern;

  Color get accent => accentPalette[accentIndex.clamp(0, accentPalette.length - 1)];

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? accentIndex,
    String? localeCode,
    double? textScale,
    bool? ghostMode,
    bool? sendByEnter,
    String? quickReaction,
    String? translateTo,
    bool? notificationsEnabled,
    bool? messagePreview,
    double? bubbleRadius,
    bool? showTranslateButton,
    bool? chatTypeTabs,
    int? keepMediaDays,
    bool? autoDownloadPhotos,
    bool? autoplayGifs,
    Set<int>? hiddenChatIds,
    String? wallpaper,
    bool? wallpaperPattern,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        accentIndex: accentIndex ?? this.accentIndex,
        localeCode: localeCode ?? this.localeCode,
        textScale: textScale ?? this.textScale,
        ghostMode: ghostMode ?? this.ghostMode,
        sendByEnter: sendByEnter ?? this.sendByEnter,
        quickReaction: quickReaction ?? this.quickReaction,
        translateTo: translateTo ?? this.translateTo,
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        messagePreview: messagePreview ?? this.messagePreview,
        bubbleRadius: bubbleRadius ?? this.bubbleRadius,
        showTranslateButton: showTranslateButton ?? this.showTranslateButton,
        chatTypeTabs: chatTypeTabs ?? this.chatTypeTabs,
        keepMediaDays: keepMediaDays ?? this.keepMediaDays,
        autoDownloadPhotos: autoDownloadPhotos ?? this.autoDownloadPhotos,
        autoplayGifs: autoplayGifs ?? this.autoplayGifs,
        hiddenChatIds: hiddenChatIds ?? this.hiddenChatIds,
        wallpaper: wallpaper ?? this.wallpaper,
        wallpaperPattern: wallpaperPattern ?? this.wallpaperPattern,
      );
}

final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('overridden in main()'),
);

class SettingsNotifier extends Notifier<AppSettings> {
  late SharedPreferences _prefs;

  @override
  AppSettings build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    return AppSettings(
      themeMode: ThemeMode.values[_prefs.getInt('themeMode') ?? ThemeMode.system.index],
      accentIndex: _prefs.getInt('accentIndex') ?? 0,
      localeCode: _prefs.getString('locale') ?? _defaultLocale(),
      textScale: _prefs.getDouble('textScale') ?? 1.0,
      ghostMode: _prefs.getBool('ghostMode') ?? false,
      sendByEnter: _prefs.getBool('sendByEnter') ?? false,
      quickReaction: _prefs.getString('quickReaction') ?? '👍',
      translateTo: _prefs.getString('translateTo') ?? _prefs.getString('locale') ?? _defaultLocale(),
      notificationsEnabled: _prefs.getBool('notifications') ?? true,
      messagePreview: _prefs.getBool('messagePreview') ?? true,
      bubbleRadius: _prefs.getDouble('bubbleRadius') ?? 18,
      showTranslateButton: _prefs.getBool('showTranslateButton') ?? true,
      chatTypeTabs: _prefs.getBool('chatTypeTabs') ?? false,
      keepMediaDays: _prefs.getInt('keepMediaDays') ?? 0,
      autoDownloadPhotos: _prefs.getBool('autoDownloadPhotos') ?? true,
      autoplayGifs: _prefs.getBool('autoplayGifs') ?? true,
      hiddenChatIds: {for (final id in _prefs.getStringList('hiddenChats') ?? const <String>[]) ?int.tryParse(id)},
      wallpaper: _prefs.getString('wallpaper') ?? '',
      wallpaperPattern: _prefs.getBool('wallpaperPattern') ?? true,
    );
  }

  static String _defaultLocale() {
    final code = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    return const {'uz', 'ru', 'en'}.contains(code) ? code : 'uz';
  }

  void setThemeMode(ThemeMode mode) {
    _prefs.setInt('themeMode', mode.index);
    state = state.copyWith(themeMode: mode);
  }

  void setAccent(int index) {
    _prefs.setInt('accentIndex', index);
    state = state.copyWith(accentIndex: index);
  }

  void setLocale(String code) {
    _prefs.setString('locale', code);
    state = state.copyWith(localeCode: code);
  }

  void setTextScale(double value) {
    _prefs.setDouble('textScale', value);
    state = state.copyWith(textScale: value);
  }

  void setGhostMode(bool value) {
    _prefs.setBool('ghostMode', value);
    state = state.copyWith(ghostMode: value);
  }

  void setSendByEnter(bool value) {
    _prefs.setBool('sendByEnter', value);
    state = state.copyWith(sendByEnter: value);
  }

  void setQuickReaction(String emoji) {
    _prefs.setString('quickReaction', emoji);
    state = state.copyWith(quickReaction: emoji);
  }

  void setTranslateTo(String code) {
    _prefs.setString('translateTo', code);
    state = state.copyWith(translateTo: code);
  }

  void setNotifications(bool value) {
    _prefs.setBool('notifications', value);
    state = state.copyWith(notificationsEnabled: value);
  }

  void setMessagePreview(bool value) {
    _prefs.setBool('messagePreview', value);
    state = state.copyWith(messagePreview: value);
  }

  void setBubbleRadius(double value) {
    _prefs.setDouble('bubbleRadius', value);
    state = state.copyWith(bubbleRadius: value);
  }

  void setKeepMediaDays(int days) {
    _prefs.setInt('keepMediaDays', days);
    state = state.copyWith(keepMediaDays: days);
  }

  void setAutoDownloadPhotos(bool value) {
    _prefs.setBool('autoDownloadPhotos', value);
    state = state.copyWith(autoDownloadPhotos: value);
  }

  void setAutoplayGifs(bool value) {
    _prefs.setBool('autoplayGifs', value);
    state = state.copyWith(autoplayGifs: value);
  }

  void setHidden(int chatId, bool hidden) {
    final next = {...state.hiddenChatIds};
    hidden ? next.add(chatId) : next.remove(chatId);
    _prefs.setStringList('hiddenChats', [for (final id in next) '$id']);
    state = state.copyWith(hiddenChatIds: next);
  }

  void setWallpaperPattern(bool value) {
    _prefs.setBool('wallpaperPattern', value);
    state = state.copyWith(wallpaperPattern: value);
  }

  void setWallpaper(String value) {
    _prefs.setString('wallpaper', value);
    state = state.copyWith(wallpaper: value);
  }

  void setChatTypeTabs(bool value) {
    _prefs.setBool('chatTypeTabs', value);
    state = state.copyWith(chatTypeTabs: value);
  }

  void setShowTranslateButton(bool value) {
    _prefs.setBool('showTranslateButton', value);
    state = state.copyWith(showTranslateButton: value);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
