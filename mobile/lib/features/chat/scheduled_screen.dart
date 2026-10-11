import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'composer.dart';

/// Messages waiting to be sent at a set time.
class ScheduledMessagesScreen extends ConsumerStatefulWidget {
  const ScheduledMessagesScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<ScheduledMessagesScreen> createState() => _ScheduledMessagesScreenState();
}

class _ScheduledMessagesScreenState extends ConsumerState<ScheduledMessagesScreen> {
  List<td.Message>? _messages;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final messages = await ref.read(accountProvider).scheduledMessages(widget.chatId);
      if (mounted) setState(() => _messages = messages);
    } on TdException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _act(td.Message message, String action) async {
    final account = ref.read(accountProvider);
    switch (action) {
      case 'now':
        await guard(context, () => account.sendScheduledNow(message));
      case 'reschedule':
        final at = await pickScheduleTime(context);
        if (at == null || !mounted) return;
        await guard(context, () => account.reschedule(message, at));
      case 'delete':
        await guard(context, () => account.deleteMessages(message.chatId, [message.id], revoke: true));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final messages = _messages;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('scheduled_messages'))),
      body: _error != null
          ? Center(child: Text(_error!))
          : messages == null
              ? const Center(child: CircularProgressIndicator())
              : messages.isEmpty
                  ? EmptyState(icon: Icons.schedule_send_rounded, title: s.t('scheduled_empty'), subtitle: '')
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        itemCount: messages.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final message = messages[index];
                          final state = message.schedulingState;
                          final when = state is td.MessageSchedulingStateSendAtDate
                              ? DateFormat.yMMMd(s.locale).add_Hm().format(fromUnix(state.sendDate))
                              : s.t('scheduled_when_online');
                          return ListTile(
                            leading: const Icon(Icons.schedule_rounded),
                            title: Text(messagePreview(message, account, s).replaceAll('\n', ' '), maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(when),
                            trailing: PopupMenuButton<String>(
                              onSelected: (action) => _act(message, action),
                              itemBuilder: (context) => [
                                PopupMenuItem(value: 'now', child: Text(s.t('send_now'))),
                                PopupMenuItem(value: 'reschedule', child: Text(s.t('reschedule'))),
                                PopupMenuItem(value: 'delete', child: Text(s.t('delete'))),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
