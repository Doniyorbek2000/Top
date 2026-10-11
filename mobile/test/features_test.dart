import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/app_lock.dart';
import 'package:sado/core/push.dart';
import 'package:sado/features/chat/message_content.dart';
import 'package:sado/l10n/strings.dart';

void main() {
  group('Telegram push payloads', () {
    final s = Strings('en');

    test('private text message', () {
      final content = PushContent.parse({
        'loc_key': 'MESSAGE_TEXT',
        'loc_args': ['Aziz', 'Salom!'],
        'custom': {'from_id': '42', 'msg_id': '7'},
      }, s, showPreview: true)!;
      expect(content.title, 'Aziz');
      expect(content.body, 'Salom!');
      expect(content.chatId, 42);
    });

    test('group media message, nested JSON payload', () {
      final content = PushContent.parse({
        'data': '{"loc_key":"CHAT_MESSAGE_PHOTO","loc_args":["Aziz","Family"],"custom":{"chat_id":"123"}}',
      }, s, showPreview: true)!;
      expect(content.title, 'Family');
      expect(content.body, 'Aziz: ${s.t('photo')}');
      expect(content.chatId, -123);
    });

    test('channel ids map to TDLib supergroup chat ids', () {
      final content = PushContent.parse({
        'loc_key': 'CHANNEL_MESSAGE_TEXT',
        'loc_args': '["News","Breaking"]',
        'custom': '{"channel_id":"777"}',
      }, s, showPreview: true)!;
      expect(content.chatId, -1000000000777);
    });

    test('previews can be hidden', () {
      final content = PushContent.parse({'loc_key': 'MESSAGE_TEXT', 'loc_args': ['A', 'secret']}, s, showPreview: false)!;
      expect(content.body, isNot(contains('secret')));
    });

    test('non-message pushes are ignored', () {
      expect(PushContent.parse({'loc_key': ''}, s, showPreview: true), isNull);
      expect(PushContent.parse({'badge': '3'}, s, showPreview: true), isNull);
    });
  });

  group('passcode hashing', () {
    test('salted and deterministic', () {
      expect(hashPasscode('1234', 'salt'), hashPasscode('1234', 'salt'));
      expect(hashPasscode('1234', 'salt'), isNot(hashPasscode('1234', 'other')));
      expect(hashPasscode('1234', 'salt'), isNot(hashPasscode('1235', 'salt')));
      expect(hashPasscode('1234', 'salt'), isNot(contains('1234')));
    });
  });

  group('invoice amounts', () {
    test('formats Stars, two-decimal and zero-decimal currencies', () {
      expect(formatInvoiceAmount(50, 'XTR'), '50 ⭐');
      expect(formatInvoiceAmount(1999, 'USD'), '19.99 USD');
      expect(formatInvoiceAmount(14900, 'UZS'), '14900 UZS');
    });
  });
}
