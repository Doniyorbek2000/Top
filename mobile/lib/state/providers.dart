import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../core/config.dart';
import 'settings.dart';
import 'telegram.dart';

/// Re-runs the calling provider whenever [listenable] notifies, and returns its current value.
T watchListenable<T>(Ref ref, ValueListenable<T> listenable) {
  void listener() => ref.invalidateSelf();
  listenable.addListener(listener);
  ref.onDispose(() => listenable.removeListener(listener));
  return listenable.value;
}

// ------------------------------------------------------------------ credentials

class CredentialsNotifier extends AsyncNotifier<TelegramCredentials?> {
  @override
  Future<TelegramCredentials?> build() => AppConfig.loadCredentials();

  Future<void> save(TelegramCredentials credentials) async {
    await AppConfig.saveCredentials(credentials);
    state = AsyncData(credentials);
  }
}

final credentialsProvider = AsyncNotifierProvider<CredentialsNotifier, TelegramCredentials?>(CredentialsNotifier.new);

// ------------------------------------------------------------------ account slots (multi-account)

class AccountSlots {
  const AccountSlots({required this.slots, required this.active, this.labels = const {}});

  final List<int> slots;
  final int active;

  /// Last known display name per slot, for the account switcher.
  final Map<int, String> labels;

  AccountSlots copyWith({List<int>? slots, int? active, Map<int, String>? labels}) =>
      AccountSlots(slots: slots ?? this.slots, active: active ?? this.active, labels: labels ?? this.labels);
}

class AccountSlotsNotifier extends Notifier<AccountSlots> {
  static const maxAccounts = 5;

  @override
  AccountSlots build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final slots = (prefs.getStringList('tg.slots') ?? const ['1']).map(int.parse).toList();
    final active = prefs.getInt('tg.active') ?? slots.first;
    final labels = <int, String>{
      for (final slot in slots) slot: prefs.getString('tg.label.$slot') ?? '',
    }..removeWhere((_, label) => label.isEmpty);
    return AccountSlots(slots: slots, active: slots.contains(active) ? active : slots.first, labels: labels);
  }

  void _persist(AccountSlots value) {
    final prefs = ref.read(sharedPreferencesProvider);
    prefs.setStringList('tg.slots', value.slots.map((s) => '$s').toList());
    prefs.setInt('tg.active', value.active);
  }

  void switchTo(int slot) {
    if (slot == state.active || !state.slots.contains(slot)) return;
    state = state.copyWith(active: slot);
    _persist(state);
  }

  /// Opens a fresh slot that starts at the phone-number screen. Returns false at the account limit.
  bool addAccount() {
    if (state.slots.length >= maxAccounts) return false;
    final slot = state.slots.fold(0, (a, b) => a > b ? a : b) + 1;
    state = state.copyWith(slots: [...state.slots, slot], active: slot);
    _persist(state);
    return true;
  }

  void setLabel(int slot, String label) {
    if (state.labels[slot] == label) return;
    ref.read(sharedPreferencesProvider).setString('tg.label.$slot', label);
    state = state.copyWith(labels: {...state.labels, slot: label});
  }

  /// Forgets a slot (after log out or an abandoned login) and wipes its local TDLib database.
  Future<void> removeSlot(int slot) async {
    final remaining = state.slots.where((s) => s != slot).toList();
    final next = remaining.isEmpty ? [slot + 1] : remaining;
    state = AccountSlots(
      slots: next,
      active: state.active == slot ? next.first : state.active,
      labels: Map.of(state.labels)..remove(slot),
    );
    _persist(state);
    ref.read(sharedPreferencesProvider).remove('tg.label.$slot');
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}${Platform.pathSeparator}tdlib${Platform.pathSeparator}account_$slot');
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException catch (error) {
      debugPrint('failed to delete account data: $error');
    }
  }
}

final accountSlotsProvider = NotifierProvider<AccountSlotsNotifier, AccountSlots>(AccountSlotsNotifier.new);

// ------------------------------------------------------------------ active Telegram account

final telegramProvider = FutureProvider<TelegramAccount?>((ref) async {
  final credentials = await ref.watch(credentialsProvider.future);
  if (credentials == null) return null;
  final slot = ref.watch(accountSlotsProvider.select((s) => s.active));
  final language = ref.read(settingsProvider).localeCode;
  final account = await TelegramAccount.start(slot, credentials, languageCode: language);
  ref.onDispose(() => unawaited(account.dispose()));

  void onAuth() {
    final state = account.authState.value;
    if (state is td.AuthorizationStateClosed && !ref.mounted) return;
    if (state is td.AuthorizationStateClosed) {
      // Logged out (here or remotely): drop this slot and move to another account.
      unawaited(ref.read(accountSlotsProvider.notifier).removeSlot(slot));
    }
  }

  account.authState.addListener(onAuth);
  ref.onDispose(() => account.authState.removeListener(onAuth));
  return account;
});

/// The active account once it is fully authorized; throws otherwise (screens below the auth gate only).
final accountProvider = Provider<TelegramAccount>((ref) {
  final account = ref.watch(telegramProvider).value;
  if (account == null) throw StateError('Telegram account is not ready');
  return account;
});

final authStateProvider = Provider<td.AuthorizationState?>((ref) {
  final account = ref.watch(telegramProvider).value;
  if (account == null) return null;
  return watchListenable(ref, account.authState);
});

final connectionStateProvider = Provider<td.ConnectionState>((ref) {
  final account = ref.watch(accountProvider);
  return watchListenable(ref, account.connectionState);
});

final chatListProvider = Provider.family<List<td.Chat>, String>((ref, listKey) {
  final account = ref.watch(accountProvider);
  watchListenable(ref, account.chatListRevision);
  return account.chatList(chatListFromKey(listKey));
});

final chatProvider = Provider.family<td.Chat?, int>((ref, chatId) {
  final account = ref.watch(accountProvider);
  watchListenable(ref, account.chatRevision(chatId));
  watchListenable(ref, account.usersRevision);
  return account.chats[chatId];
});

final userProvider = Provider.family<td.User?, int>((ref, userId) {
  final account = ref.watch(accountProvider);
  watchListenable(ref, account.usersRevision);
  return account.users[userId];
});

/// Changes whenever any user (status, name, photo) changes.
final usersRevisionProvider = Provider<int>((ref) {
  final account = ref.watch(accountProvider);
  return watchListenable(ref, account.usersRevision);
});

final meProvider = Provider<td.User?>((ref) {
  final account = ref.watch(accountProvider);
  watchListenable(ref, account.usersRevision);
  return account.me;
});

final foldersProvider = Provider<List<td.ChatFolderInfo>>((ref) {
  final account = ref.watch(accountProvider);
  watchListenable(ref, account.foldersRevision);
  return account.folders;
});

final unreadCountProvider = Provider.family<int, String>((ref, listKey) {
  final account = ref.watch(accountProvider);
  watchListenable(ref, account.foldersRevision);
  return account.unreadCounts[listKey] ?? 0;
});

/// Local path of a file once downloaded; starts the download on first watch.
final fileProvider = StreamProvider.autoDispose.family<td.File?, int>((ref, fileId) async* {
  final account = ref.watch(accountProvider);
  final cached = account.files[fileId];
  yield cached;
  if (cached == null || !cached.local.isDownloadingCompleted) {
    unawaited(account.downloadFile(fileId));
  }
  yield* account.fileUpdates(fileId);
});

/// The chat currently on screen (suppresses notifications, marks messages as read).
class OpenChatNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? chatId) => state = chatId;
}

final openChatProvider = NotifierProvider<OpenChatNotifier, int?>(OpenChatNotifier.new);
