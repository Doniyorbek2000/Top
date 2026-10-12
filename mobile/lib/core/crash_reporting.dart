import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'redaction.dart';

/// Crash reporting is opt-in at build time: `--dart-define=SENTRY_DSN=https://...`.
/// Reports carry stack traces and device info only: no user identity, breadcrumbs,
/// screenshots or message text, and every string is passed through [redactSecrets].
class CrashReporting {
  static const dsn = String.fromEnvironment('SENTRY_DSN');

  static bool get enabled => dsn.isNotEmpty && !kDebugMode;

  static Future<void> run(Future<void> Function() appRunner) async {
    if (!enabled) {
      await appRunner();
      return;
    }
    await SentryFlutter.init(
      (options) {
        options
          ..dsn = dsn
          ..sendDefaultPii = false
          ..maxBreadcrumbs = 0
          ..attachScreenshot = false
          ..tracesSampleRate = 0
          ..beforeSend = _scrub;
      },
      appRunner: appRunner,
    );
  }

  static SentryEvent? _scrub(SentryEvent event, Hint hint) {
    event
      ..user = null
      ..request = null
      ..breadcrumbs = const [];
    final message = event.message;
    if (message != null) event.message = SentryMessage(redactSecrets(message.formatted));
    for (final exception in event.exceptions ?? const <SentryException>[]) {
      final value = exception.value;
      if (value != null) exception.value = redactSecrets(value);
    }
    return event;
  }
}
