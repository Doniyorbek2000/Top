import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/redaction.dart';
import 'package:sado/state/actions.dart';
import 'package:tdlib_ex/td_api.dart' as td;
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

  group('markdown formatting', () {
    final hasTdlib = (Platform.environment['TDJSON_PATH'] ?? '').isNotEmpty;

    test('plain text skips the parser', () {
      final text = formattedText('just text, no markup');
      expect(text.text, 'just text, no markup');
      expect(text.entities, isEmpty);
    });

    test('TDLib parses bold, italic, spoiler and links', () {
      final text = formattedText('**bold** __it__ ||hide|| [site](https://sado.uz)');
      expect(text.text, 'bold it hide site');
      final types = text.entities.map((e) => e.type.runtimeType).toSet();
      expect(types, containsAll([td.TextEntityTypeBold, td.TextEntityTypeItalic, td.TextEntityTypeSpoiler, td.TextEntityTypeTextUrl]));
    }, skip: hasTdlib ? false : 'needs TDJSON_PATH');

    test('toMarkdown round-trips through the parser', () {
      const source = '**bold** and `code` and [link](https://example.com/)';
      final parsed = formattedText(source);
      expect(formattedText(toMarkdown(parsed)).entities.length, parsed.entities.length);
      expect(formattedText(toMarkdown(parsed)).text, parsed.text);
    }, skip: hasTdlib ? false : 'needs TDJSON_PATH');

    test('toMarkdown writes markers for entities', () {
      final text = td.FormattedText(text: 'hi there', entities: [
        td.TextEntity(offset: 0, length: 2, type: const td.TextEntityTypeBold()),
        td.TextEntity(offset: 3, length: 5, type: const td.TextEntityTypeTextUrl(url: 'https://t.me')),
      ]);
      expect(toMarkdown(text), '**hi** [there](https://t.me)');
    });
  });

  group('proxy links', () {
    test('MTProto link', () {
      final proxy = parseProxyLink('https://t.me/proxy?server=1.2.3.4&port=443&secret=ee00ff')!;
      expect(proxy.server, '1.2.3.4');
      expect(proxy.port, 443);
      expect((proxy.type as td.ProxyTypeMtproto).secret, 'ee00ff');
    });

    test('SOCKS5 tg:// link with credentials', () {
      final proxy = parseProxyLink('tg://socks?server=proxy.example&port=1080&user=a&pass=b')!;
      expect(proxy.type, isA<td.ProxyTypeSocks5>());
      expect((proxy.type as td.ProxyTypeSocks5).username, 'a');
    });

    test('invalid links are rejected', () {
      expect(parseProxyLink('https://t.me/proxy?server=x&port=99999&secret=a'), isNull);
      expect(parseProxyLink('https://t.me/proxy?server=x&port=443'), isNull);
      expect(parseProxyLink('not a link'), isNull);
    });
  });

  group('crash report redaction', () {
    test('removes API hashes, tokens and phone numbers', () {
      final out = redactSecrets('api_hash=0123456789abcdef0123456789abcdef token: abc.def phone +998901234567');
      expect(out, isNot(contains('0123456789abcdef')));
      expect(out, isNot(contains('abc.def')));
      expect(out, isNot(contains('998901234567')));
    });
  });
}

