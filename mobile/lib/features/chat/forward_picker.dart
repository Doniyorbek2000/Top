import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

/// Picks a chat to forward messages to; pops with the chat id.
class ForwardPickerScreen extends ConsumerStatefulWidget {
  const ForwardPickerScreen({super.key});

  @override
  ConsumerState<ForwardPickerScreen> createState() => _ForwardPickerScreenState();
}

class _ForwardPickerScreenState extends ConsumerState<ForwardPickerScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final chats = ref
        .watch(chatListProvider('main'))
        .where((c) => account.canSendMessages(c))
        .where((c) => _query.isEmpty || chatTitle(c, account, s).toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: s.t('forward_to'),
            hintStyle: const TextStyle(color: Colors.white70),
            border: InputBorder.none,
          ),
          onChanged: (value) => setState(() => _query = value.trim()),
        ),
      ),
      body: ListView.builder(
        itemCount: chats.length,
        itemBuilder: (context, index) {
          final chat = chats[index];
          return ListTile(
            leading: ChatAvatar(chatId: chat.id, size: 44),
            title: Text(chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(chatSubtitle(chat, account, s), maxLines: 1),
            onTap: () => Navigator.pop(context, chat.id),
          );
        },
      ),
    );
  }
}
