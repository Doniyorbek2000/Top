import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../l10n/strings.dart';
import '../state/settings.dart';

/// Local passcode that locks the Sado UI (Telegram's "Passcode Lock"). The PIN never leaves the
/// device: only a salted, stretched SHA-256 is kept in the platform keystore.
class AppLockState {
  const AppLockState({required this.enabled, required this.locked, required this.autoLockMinutes, this.lockedUntil});

  final bool enabled;
  final bool locked;

  /// 0 = lock every time the app goes to the background.
  final int autoLockMinutes;

  /// Set after too many wrong attempts.
  final DateTime? lockedUntil;

  AppLockState copyWith({bool? enabled, bool? locked, int? autoLockMinutes, DateTime? lockedUntil, bool clearCooldown = false}) =>
      AppLockState(
        enabled: enabled ?? this.enabled,
        locked: locked ?? this.locked,
        autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
        lockedUntil: clearCooldown ? null : (lockedUntil ?? this.lockedUntil),
      );
}

String hashPasscode(String pin, String salt) {
  List<int> digest = utf8.encode('$salt:$pin');
  for (var i = 0; i < 20000; i++) {
    digest = sha256.convert(digest).bytes;
  }
  return base64Encode(digest);
}

class AppLockNotifier extends Notifier<AppLockState> {
  static const _storage = FlutterSecureStorage();
  static const _hashKey = 'sado.lock.hash';
  static const _saltKey = 'sado.lock.salt';
  static const maxAttempts = 5;

  int _failedAttempts = 0;
  DateTime? _backgroundedAt;

  @override
  AppLockState build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final enabled = prefs.getBool('lock.enabled') ?? false;
    // Start locked so no chat content is visible before the PIN is entered.
    return AppLockState(enabled: enabled, locked: enabled, autoLockMinutes: prefs.getInt('lock.autoMinutes') ?? 1);
  }

  Future<void> enable(String pin) async {
    final random = Random.secure();
    final salt = base64Encode(List<int>.generate(16, (_) => random.nextInt(256)));
    await _storage.write(key: _saltKey, value: salt);
    await _storage.write(key: _hashKey, value: hashPasscode(pin, salt));
    await ref.read(sharedPreferencesProvider).setBool('lock.enabled', true);
    state = state.copyWith(enabled: true, locked: false);
  }

  Future<void> disable() async {
    await _storage.delete(key: _hashKey);
    await _storage.delete(key: _saltKey);
    await ref.read(sharedPreferencesProvider).setBool('lock.enabled', false);
    state = state.copyWith(enabled: false, locked: false);
  }

  Future<void> setAutoLock(int minutes) async {
    await ref.read(sharedPreferencesProvider).setInt('lock.autoMinutes', minutes);
    state = state.copyWith(autoLockMinutes: minutes);
  }

  /// Checks a PIN without unlocking (used before changing or disabling the passcode).
  Future<bool> verify(String pin) async {
    final salt = await _storage.read(key: _saltKey);
    final hash = await _storage.read(key: _hashKey);
    if (salt == null || hash == null) return false;
    return hashPasscode(pin, salt) == hash;
  }

  /// Returns true when unlocked; applies a growing cooldown after repeated failures.
  Future<bool> unlock(String pin) async {
    final until = state.lockedUntil;
    if (until != null && DateTime.now().isBefore(until)) return false;
    if (await verify(pin)) {
      _failedAttempts = 0;
      state = state.copyWith(locked: false, clearCooldown: true);
      return true;
    }
    _failedAttempts++;
    if (_failedAttempts >= maxAttempts) {
      final seconds = 30 * (1 << (_failedAttempts - maxAttempts).clamp(0, 5));
      state = state.copyWith(lockedUntil: DateTime.now().add(Duration(seconds: seconds)));
    }
    return false;
  }

  void lockNow() {
    if (state.enabled) state = state.copyWith(locked: true);
  }

  void onBackground() => _backgroundedAt ??= DateTime.now();

  void onForeground() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (!state.enabled || since == null) return;
    if (DateTime.now().difference(since) >= Duration(minutes: state.autoLockMinutes)) {
      state = state.copyWith(locked: true);
    }
  }
}

final appLockProvider = NotifierProvider<AppLockNotifier, AppLockState>(AppLockNotifier.new);

/// Covers the whole app with the lock screen while locked.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final lock = ref.read(appLockProvider.notifier);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      lock.onBackground();
    } else if (state == AppLifecycleState.resumed) {
      lock.onForeground();
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = ref.watch(appLockProvider.select((s) => s.locked));
    return Stack(
      children: [
        // Offstage keeps navigation state but stops the UI from painting or receiving input.
        Offstage(offstage: locked, child: TickerMode(enabled: !locked, child: widget.child)),
        if (locked) const Positioned.fill(child: _LockScreen()),
      ],
    );
  }
}

class _LockScreen extends ConsumerStatefulWidget {
  const _LockScreen();

  @override
  ConsumerState<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<_LockScreen> {
  String _pin = '';
  bool _error = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(appLockProvider).lockedUntil != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _submit(String pin) async {
    final ok = await ref.read(appLockProvider.notifier).unlock(pin);
    if (!mounted) return;
    if (!ok) {
      HapticFeedback.heavyImpact();
      setState(() {
        _pin = '';
        _error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(ref.watch(settingsProvider).localeCode);
    final until = ref.watch(appLockProvider).lockedUntil;
    final wait = until == null ? 0 : until.difference(DateTime.now()).inSeconds;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: PinPad(
          title: wait > 0 ? s.t('passcode_wait', {'seconds': '$wait'}) : s.t(_error ? 'passcode_wrong' : 'passcode_enter'),
          pin: _pin,
          error: _error,
          enabled: wait <= 0,
          onChanged: (pin) {
            setState(() {
              _pin = pin;
              _error = false;
            });
            if (pin.length == PinPad.length) unawaited(_submit(pin));
          },
        ),
      ),
    );
  }
}

/// Numeric keypad with dot indicators.
class PinPad extends StatelessWidget {
  const PinPad({super.key, required this.title, required this.pin, required this.onChanged, this.error = false, this.enabled = true});

  static const length = 4;

  final String title;
  final String pin;
  final ValueChanged<String> onChanged;
  final bool error;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget key(String label, {IconData? icon, VoidCallback? onTap}) => SizedBox.square(
          dimension: 76,
          child: TextButton(
            style: TextButton.styleFrom(shape: const CircleBorder(), foregroundColor: scheme.onSurface),
            onPressed: enabled ? onTap : null,
            child: icon != null ? Icon(icon, size: 26) : Text(label, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500)),
          ),
        );
    void digit(String d) {
      if (pin.length < length) onChanged(pin + d);
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset('assets/logo.png', width: 72, height: 72),
        const SizedBox(height: 20),
        Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, color: error ? scheme.error : null)),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < length; i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 9),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < pin.length ? (error ? scheme.error : scheme.primary) : Colors.transparent,
                  border: Border.all(color: error ? scheme.error : scheme.primary, width: 1.6),
                ),
              ),
          ],
        ),
        const SizedBox(height: 32),
        for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final d in row) key(d, onTap: () => digit(d))]),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox.square(dimension: 76),
            key('0', onTap: () => digit('0')),
            key('', icon: Icons.backspace_outlined, onTap: pin.isEmpty ? null : () => onChanged(pin.substring(0, pin.length - 1))),
          ],
        ),
      ],
    );
  }
}

/// Settings page: turn the passcode on/off, change it, pick the auto-lock delay.
class PasscodeSettingsScreen extends ConsumerWidget {
  const PasscodeSettingsScreen({super.key});

  Future<String?> _askNewPin(BuildContext context) async {
    final first = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const PinEntryScreen(titleKey: 'passcode_new')));
    if (first == null || !context.mounted) return null;
    final second = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const PinEntryScreen(titleKey: 'passcode_repeat')));
    if (second == null || !context.mounted) return null;
    if (first != second) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('passcode_mismatch'))));
      return null;
    }
    return first;
  }

  Future<bool> _checkCurrent(BuildContext context, WidgetRef ref) async {
    final pin = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const PinEntryScreen(titleKey: 'passcode_enter')));
    if (pin == null) return false;
    final ok = await ref.read(appLockProvider.notifier).verify(pin);
    if (!ok && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('passcode_wrong'))));
    return ok;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(appLockProvider);
    final notifier = ref.read(appLockProvider.notifier);
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('passcode_lock'))),
      body: ListView(
        children: [
          SwitchListTile(
            title: Text(s.t('passcode_lock')),
            subtitle: Text(s.t('passcode_hint')),
            value: lock.enabled,
            onChanged: (value) async {
              if (value) {
                final pin = await _askNewPin(context);
                if (pin != null) await notifier.enable(pin);
              } else if (await _checkCurrent(context, ref)) {
                await notifier.disable();
              }
            },
          ),
          if (lock.enabled) ...[
            ListTile(
              leading: const Icon(Icons.password_rounded),
              title: Text(s.t('passcode_change')),
              onTap: () async {
                if (!await _checkCurrent(context, ref) || !context.mounted) return;
                final pin = await _askNewPin(context);
                if (pin != null) await notifier.enable(pin);
              },
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text(s.t('passcode_auto_lock')),
              trailing: DropdownButton<int>(
                value: lock.autoLockMinutes,
                underline: const SizedBox.shrink(),
                items: [
                  for (final minutes in const [0, 1, 5, 60, 300])
                    DropdownMenuItem(
                      value: minutes,
                      child: Text(minutes == 0 ? s.t('passcode_immediately') : s.t('passcode_after_minutes', {'n': '$minutes'})),
                    ),
                ],
                onChanged: (v) => v == null ? null : notifier.setAutoLock(v),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.lock_rounded),
              title: Text(s.t('passcode_lock_now')),
              onTap: () {
                Navigator.of(context).popUntil((route) => route.isFirst);
                notifier.lockNow();
              },
            ),
          ],
        ],
      ),
    );
  }
}

class PinEntryScreen extends StatefulWidget {
  const PinEntryScreen({super.key, required this.titleKey});

  final String titleKey;

  @override
  State<PinEntryScreen> createState() => _PinEntryScreenState();
}

class _PinEntryScreenState extends State<PinEntryScreen> {
  String _pin = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: PinPad(
        title: context.t(widget.titleKey),
        pin: _pin,
        onChanged: (pin) {
          setState(() => _pin = pin);
          if (pin.length == PinPad.length) Navigator.pop(context, pin);
        },
      ),
    );
  }
}
