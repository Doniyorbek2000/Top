import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../state/actions.dart';
import '../state/telegram.dart';

class _LiveShare {
  _LiveShare(this.account, this.chatId, this.messageId, this.until);

  final TelegramAccount account;
  final int chatId;
  final int messageId;
  final DateTime until;
}

/// Keeps outgoing live locations updated while the app runs (Telegram stops them at the end of the period).
class LiveLocationService {
  LiveLocationService._();

  static final LiveLocationService instance = LiveLocationService._();

  final List<_LiveShare> _shares = [];
  StreamSubscription<Position>? _positions;
  final ValueNotifier<int> revision = ValueNotifier(0);

  bool isSharing(int chatId, int messageId) => _shares.any((s) => s.chatId == chatId && s.messageId == messageId);

  Future<bool> start(TelegramAccount account, int chatId, Duration period) async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return false;
    final position = await Geolocator.getCurrentPosition();
    final message = await account.sendLiveLocation(chatId, position.latitude, position.longitude, periodSeconds: period.inSeconds);
    _shares.add(_LiveShare(account, chatId, message.id, DateTime.now().add(period)));
    _ensureListening();
    revision.value++;
    return true;
  }

  /// Message ids change when a message is confirmed by the server; keep tracking the new id.
  void onMessageIdChanged(int chatId, int oldId, int newId) {
    final index = _shares.indexWhere((s) => s.chatId == chatId && s.messageId == oldId);
    if (index < 0) return;
    final old = _shares[index];
    _shares[index] = _LiveShare(old.account, chatId, newId, old.until);
  }

  Future<void> stop(TelegramAccount account, int chatId, int messageId) async {
    _shares.removeWhere((s) => s.chatId == chatId && s.messageId == messageId);
    revision.value++;
    if (_shares.isEmpty) await _positions?.cancel().then((_) => _positions = null);
    try {
      await account.updateLiveLocation(chatId, messageId);
    } on Object catch (error) {
      debugPrint('stop live location failed: $error');
    }
  }

  void _ensureListening() {
    _positions ??= Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 25),
    ).listen(_onPosition, onError: (Object error) => debugPrint('position stream failed: $error'));
  }

  void _onPosition(Position position) {
    final now = DateTime.now();
    _shares.removeWhere((s) => now.isAfter(s.until));
    if (_shares.isEmpty) {
      unawaited(_positions?.cancel());
      _positions = null;
      revision.value++;
      return;
    }
    for (final share in List.of(_shares)) {
      unawaited(share.account
          .updateLiveLocation(share.chatId, share.messageId, latitude: position.latitude, longitude: position.longitude)
          .catchError((Object error) => debugPrint('live location update failed: $error')));
    }
  }
}
