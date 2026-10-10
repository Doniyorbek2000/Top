import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'translations.dart';

/// Lightweight localization: string tables per language with `{placeholder}` substitution.
class Strings {
  const Strings(this.locale);

  final String locale;

  static const supported = ['uz', 'ru', 'en'];
  static const languageNames = {'uz': "O'zbekcha", 'ru': 'Русский', 'en': 'English'};

  static Strings of(BuildContext context) => Localizations.of<Strings>(context, Strings) ?? const Strings('uz');

  String t(String key, [Map<String, String>? params]) {
    var value = translations[locale]?[key] ?? translations['en']?[key];
    if (value == null) {
      assert(() {
        debugPrint('Missing translation: $key');
        return true;
      }());
      value = key;
    }
    if (params != null) {
      params.forEach((name, replacement) => value = value!.replaceAll('{$name}', replacement));
    }
    return value!;
  }

  /// Plural-aware count label, e.g. members: "1 a'zo" / "5 участников".
  String count(String key, int n) {
    if (locale == 'ru') {
      final mod10 = n % 10;
      final mod100 = n % 100;
      final form = (mod10 == 1 && mod100 != 11)
          ? 'one'
          : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
              ? 'few'
              : 'many';
      return t('${key}_$form', {'n': '$n'});
    }
    return t(n == 1 ? '${key}_one' : '${key}_many', {'n': '$n'});
  }

  /// Human-readable text for an API error code.
  String error(String code) {
    final key = 'err_$code';
    final value = translations[locale]?[key] ?? translations['en']?[key];
    return value ?? t('err_GENERIC');
  }
}

class StringsDelegate extends LocalizationsDelegate<Strings> {
  const StringsDelegate();

  @override
  bool isSupported(Locale locale) => Strings.supported.contains(locale.languageCode);

  @override
  Future<Strings> load(Locale locale) => SynchronousFuture(Strings(locale.languageCode));

  @override
  bool shouldReload(StringsDelegate old) => false;
}

extension StringsX on BuildContext {
  Strings get s => Strings.of(this);

  String t(String key, [Map<String, String>? params]) => Strings.of(this).t(key, params);
}
