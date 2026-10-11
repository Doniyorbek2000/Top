import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sado/l10n/strings.dart';
import 'package:sado/l10n/translations.dart';
import 'package:sado/state/actions.dart';

void main() {
  group('voice note waveform', () {
    test('5-bit packing round-trips', () {
      final samples = [for (var i = 0; i < 100; i++) (i * 7) % 32];
      final decoded = decodeWaveform(encodeWaveform(samples));
      expect(decoded.sublist(0, samples.length), samples);
    });

    test('values are clamped to 0..31', () {
      expect(decodeWaveform(encodeWaveform([-5, 40, 31])).take(3), [0, 31, 31]);
    });

    test('empty waveform decodes to nothing', () => expect(decodeWaveform(''), isEmpty));
  });

  group('translations', () {
    test('every language defines the same keys', () {
      final reference = translations['en']!.keys.toSet();
      for (final entry in translations.entries) {
        final keys = entry.value.keys.where((k) => !k.endsWith('_few')).toSet();
        expect(keys.difference(reference), isEmpty, reason: '${entry.key} has extra keys');
        expect(reference.difference(keys), isEmpty, reason: '${entry.key} is missing keys');
      }
    });

    test('Russian plurals have all three forms', () {
      final ru = translations['ru']!;
      for (final key in ru.keys.where((k) => k.endsWith('_many'))) {
        final base = key.substring(0, key.length - 5);
        expect(ru.containsKey('${base}_one') && ru.containsKey('${base}_few'), isTrue, reason: base);
      }
    });

    test('every key used in the code exists', () {
      final used = <String>{};
      final literal = RegExp(r"'([a-z][a-z0-9_]*)'");
      final call = RegExp(r'(\.t\(|\.count\(|context\.t\()');
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        if (file.path.contains('l10n')) continue;
        for (final line in file.readAsLinesSync().where(call.hasMatch)) {
          used.addAll(literal.allMatches(line).map((m) => m.group(1)!));
        }
      }
      final en = translations['en']!;
      // Literals on t()/count() lines that are values or placeholders, not keys.
      const notKeys = {
        'actor', 'users', 'title', 'n', 'name', 'time', 'date', 'email', 'phone', 'prefix', 'lang', 'hint', 'link',
        'main', 'fix', 'translate', 'emoji', 'summarize', 'clear', 'mute', 'delete', 'pin', 'retry', 'reply', 'copy',
        'edit', 'forward', 'share', 'select', 'gallery', 'camera', 'video', 'file', 'location', 'poll', 'contact', 'read',
        'archive', 'count', 'domain', 'seconds', 'bot', 'now', 'scheduled', 'reschedule', 'admins', 'dismiss', 'remove', 'version',
      };
      final missing = used.where((k) => !notKeys.contains(k) && !en.containsKey(k) && !en.containsKey('${k}_one')).toList()..sort();
      expect(missing, isEmpty);
    });

    test('placeholders and plural selection', () {
      const ru = Strings('ru');
      expect(ru.count('members', 1), '1 участник');
      expect(ru.count('members', 3), '3 участника');
      expect(ru.count('members', 11), '11 участников');
      expect(ru.count('members', 21), '21 участник');
      expect(const Strings('en').count('votes', 2), '2 votes');
      expect(const Strings('uz').t('resend_in', {'n': '30'}), 'Kodni qayta yuborish: 30 s');
      expect(const Strings('uz').error('NOT_A_REAL_CODE'), const Strings('uz').t('err_GENERIC'));
    });
  });
}
