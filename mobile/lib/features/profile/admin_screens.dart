import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';

/// Entry list of admin tools for a group or channel.
class ManageChatScreen extends ConsumerWidget {
  const ManageChatScreen({super.key, required this.chatId});

  final int chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final chat = ref.watch(chatProvider(chatId));
    final s = context.s;
    if (chat == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final status = account.myStatus(chat);
    final rights = status is td.ChatMemberStatusAdministrator ? status.rights : null;
    final isCreator = status is td.ChatMemberStatusCreator;
    final canRestrict = isCreator || (rights?.canRestrictMembers ?? false);
    final canInvite = isCreator || (rights?.canInviteUsers ?? false);
    final isChannel = account.isChannel(chat);
    void push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    return Scaffold(
      appBar: AppBar(title: Text(s.t('manage'))),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_rounded),
            title: Text(s.t('administrators')),
            onTap: () => push(MembersScreen(chatId: chatId, filter: 'admins')),
          ),
          ListTile(
            leading: const Icon(Icons.group_rounded),
            title: Text(s.t(isChannel ? 'subscribers_title' : 'members_title')),
            onTap: () => push(MembersScreen(chatId: chatId)),
          ),
          if (!isChannel && canRestrict)
            ListTile(
              leading: const Icon(Icons.key_rounded),
              title: Text(s.t('permissions')),
              onTap: () => openPermissions(context, ref, chatId),
            ),
          if (canRestrict && account.supergroupOf(chat) != null) ...[
            ListTile(
              leading: const Icon(Icons.person_off_rounded),
              title: Text(s.t('restricted_users')),
              onTap: () => push(MembersScreen(chatId: chatId, filter: 'restricted')),
            ),
            ListTile(
              leading: const Icon(Icons.block_rounded),
              title: Text(s.t('banned_users')),
              onTap: () => push(MembersScreen(chatId: chatId, filter: 'banned')),
            ),
          ],
          if (canInvite) ...[
            ListTile(
              leading: const Icon(Icons.link_rounded),
              title: Text(s.t('invite_links')),
              onTap: () => push(InviteLinksScreen(chatId: chatId)),
            ),
            ListTile(
              leading: const Icon(Icons.how_to_reg_rounded),
              title: Text(s.t('join_requests')),
              trailing: chat.pendingJoinRequests != null && chat.pendingJoinRequests!.totalCount > 0
                  ? Badge(label: Text('${chat.pendingJoinRequests!.totalCount}'))
                  : null,
              onTap: () => push(JoinRequestsScreen(chatId: chatId)),
            ),
          ],
          if (isCreator || (rights?.canChangeInfo ?? false) || (rights?.canDeleteMessages ?? false))
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text(s.t('auto_delete')),
              subtitle: Text(chat.messageAutoDeleteTime == 0 ? s.t('off') : _durationLabel(s, chat.messageAutoDeleteTime)),
              onTap: () async {
                final value = await _pickSeconds(context, s, const [0, 86400, 604800, 2592000], chat.messageAutoDeleteTime);
                if (value != null && context.mounted) await guard(context, () => account.setAutoDelete(chatId, value));
              },
            ),
        ],
      ),
    );
  }
}

String _durationLabel(Strings s, int seconds) {
  if (seconds == 0) return s.t('off');
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  if (seconds < 86400) return '${seconds ~/ 3600}h';
  return s.t('keep_days', {'n': '${seconds ~/ 86400}'});
}

Future<int?> _pickSeconds(BuildContext context, Strings s, List<int> options, int current) => showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options)
              ListTile(
                title: Text(_durationLabel(s, option)),
                trailing: option == current ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
                onTap: () => Navigator.pop(context, option),
              ),
          ],
        ),
      ),
    );

// ------------------------------------------------------------------ members

class MembersScreen extends ConsumerStatefulWidget {
  const MembersScreen({super.key, required this.chatId, this.filter = 'recent'});

  final int chatId;
  final String filter;

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  List<td.ChatMember>? _members;
  String _query = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    final chat = account.chats[widget.chatId];
    if (chat == null) return;
    try {
      var members = await account.members(chat, filter: widget.filter, query: _query);
      if (account.supergroupOf(chat) == null && _query.isNotEmpty) {
        final q = _query.toLowerCase();
        members = members.where((m) => account.senderName(m.memberId).toLowerCase().contains(q)).toList();
      }
      if (mounted) setState(() => _members = members);
    } on TdException catch (error) {
      if (mounted) showToast(context, error.message);
    }
  }

  String _title(Strings s) => switch (widget.filter) {
        'admins' => s.t('administrators'),
        'restricted' => s.t('restricted_users'),
        'banned' => s.t('banned_users'),
        _ => s.t('members_title'),
      };

  String _statusLabel(Strings s, td.ChatMemberStatus status) => switch (status) {
        td.ChatMemberStatusCreator() => s.t('owner'),
        td.ChatMemberStatusAdministrator() => s.t('admin'),
        td.ChatMemberStatusRestricted() => s.t('restricted'),
        td.ChatMemberStatusBanned() => s.t('banned'),
        _ => '',
      };

  Future<void> _memberActions(td.ChatMember member) async {
    final account = ref.read(accountProvider);
    final chat = account.chats[widget.chatId];
    final sender = member.memberId;
    if (chat == null || sender is! td.MessageSenderUser || sender.userId == account.myId) return;
    final s = context.s;
    final mine = account.myStatus(chat);
    final isCreator = mine is td.ChatMemberStatusCreator;
    final myRights = mine is td.ChatMemberStatusAdministrator ? mine.rights : null;
    final canPromote = isCreator || (myRights?.canPromoteMembers ?? false);
    final canRestrict = isCreator || (myRights?.canRestrictMembers ?? false);
    final status = member.status;
    final isAdmin = status is td.ChatMemberStatusAdministrator;
    final isOwner = status is td.ChatMemberStatusCreator;
    if (isOwner) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.chat_rounded), title: Text(s.t('send_message')), onTap: () => Navigator.pop(context, 'message')),
            if (canPromote && (!isAdmin || status.canBeEdited))
              ListTile(
                leading: const Icon(Icons.admin_panel_settings_rounded),
                title: Text(s.t(isAdmin ? 'edit_admin' : 'promote')),
                onTap: () => Navigator.pop(context, 'promote'),
              ),
            if (canPromote && isAdmin && status.canBeEdited)
              ListTile(leading: const Icon(Icons.remove_moderator_rounded), title: Text(s.t('dismiss_admin')), onTap: () => Navigator.pop(context, 'dismiss')),
            if (canRestrict && !isAdmin && !account.isChannel(chat) && status is! td.ChatMemberStatusBanned)
              ListTile(leading: const Icon(Icons.person_off_rounded), title: Text(s.t('restrict')), onTap: () => Navigator.pop(context, 'restrict')),
            if (canRestrict && (status is td.ChatMemberStatusBanned || status is td.ChatMemberStatusRestricted))
              ListTile(leading: const Icon(Icons.lock_open_rounded), title: Text(s.t('unban')), onTap: () => Navigator.pop(context, 'unban')),
            if (canRestrict && !isAdmin && status is! td.ChatMemberStatusBanned)
              ListTile(
                leading: Icon(Icons.block_rounded, color: Theme.of(context).colorScheme.error),
                title: Text(s.t('ban'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () => Navigator.pop(context, 'ban'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final userId = sender.userId;
    switch (action) {
      case 'message':
        final private = await guard(context, () => account.openPrivateChat(userId));
        if (private != null && mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
          openChat(context, private.id);
        }
      case 'promote':
        final rights = await Navigator.of(context).push<td.ChatAdministratorRights>(MaterialPageRoute(
          builder: (_) => RightsEditor(
            title: account.userName(userId),
            isChannel: account.isChannel(chat),
            initial: isAdmin ? status.rights : null,
          ),
        ));
        if (rights == null || !mounted) return;
        await guard(context, () => account.setMemberStatus(widget.chatId, userId, td.ChatMemberStatusAdministrator(canBeEdited: true, rights: rights)));
      case 'dismiss':
        await guard(context, () => account.setMemberStatus(widget.chatId, userId, const td.ChatMemberStatusMember(memberUntilDate: 0)));
      case 'restrict':
        final permissions = await Navigator.of(context).push<td.ChatPermissions>(MaterialPageRoute(
          builder: (_) => PermissionsEditor(title: account.userName(userId), initial: status is td.ChatMemberStatusRestricted ? status.permissions : chat.permissions),
        ));
        if (permissions == null || !mounted) return;
        await guard(context, () => account.setMemberStatus(
              widget.chatId,
              userId,
              td.ChatMemberStatusRestricted(isMember: true, restrictedUntilDate: 0, permissions: permissions),
            ));
      case 'unban':
        await guard(context, () => account.setMemberStatus(
              widget.chatId,
              userId,
              status is td.ChatMemberStatusBanned ? const td.ChatMemberStatusLeft() : const td.ChatMemberStatusMember(memberUntilDate: 0),
            ));
      case 'ban':
        final ok = await confirm(context, title: s.t('ban'), message: s.t('ban_confirm', {'name': account.userName(userId)}), destructive: true);
        if (ok && mounted) await guard(context, () => account.banMember(widget.chatId, userId));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final members = _members;
    return Scaffold(
      appBar: AppBar(title: Text(_title(s))),
      body: Column(
        children: [
          if (widget.filter != 'admins')
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: s.t('search'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                ),
                onChanged: (q) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 350), () {
                    _query = q.trim();
                    unawaited(_load());
                  });
                },
              ),
            ),
          Expanded(
            child: members == null
                ? const Center(child: CircularProgressIndicator())
                : members.isEmpty
                    ? Center(child: Text(s.t('nothing_found')))
                    : ListView.builder(
                        itemCount: members.length,
                        itemBuilder: (context, index) {
                          final member = members[index];
                          final sender = member.memberId;
                          final userId = sender is td.MessageSenderUser ? sender.userId : 0;
                          final user = account.users[userId];
                          final label = _statusLabel(s, member.status);
                          return ListTile(
                            leading: userId != 0 ? UserAvatar(userId: userId, size: 42) : const CircleAvatar(child: Icon(Icons.group_rounded)),
                            title: Text(account.senderName(sender), maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              member.tag.isNotEmpty ? member.tag : (user != null ? formatUserStatus(user, s) : ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: label.isEmpty ? null : Text(label, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12.5)),
                            onTap: () => _memberActions(member),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ rights / permissions editors

/// Toggles over a TDLib object's boolean fields, edited through its JSON form so new
/// TDLib fields keep their current values instead of being reset.
class _ToggleEditor<T extends td.TdObject> extends StatefulWidget {
  const _ToggleEditor({required this.title, required this.initial, required this.fields, this.footer});

  final String title;
  final Map<String, dynamic> initial;
  final List<(String, String)> fields;
  final Widget? footer;

  @override
  State<_ToggleEditor<T>> createState() => _ToggleEditorState<T>();
}

class _ToggleEditorState<T extends td.TdObject> extends State<_ToggleEditor<T>> {
  late final Map<String, dynamic> _values = Map.of(widget.initial);

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _values.toTdObject() as T),
            child: Text(s.t('save'), style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: ListView(
        children: [
          for (final (key, label) in widget.fields)
            SwitchListTile(
              title: Text(s.t(label)),
              value: _values[key] == true,
              onChanged: (v) => setState(() => _values[key] = v),
            ),
          ?widget.footer,
        ],
      ),
    );
  }
}

class RightsEditor extends StatelessWidget {
  const RightsEditor({super.key, required this.title, required this.isChannel, this.initial});

  final String title;
  final bool isChannel;
  final td.ChatAdministratorRights? initial;

  @override
  Widget build(BuildContext context) {
    final base = initial?.toJson() ??
        {
          '@type': 'chatAdministratorRights',
          'can_manage_chat': true,
          'can_change_info': true,
          'can_post_messages': isChannel,
          'can_edit_messages': isChannel,
          'can_delete_messages': true,
          'can_invite_users': true,
          'can_restrict_members': !isChannel,
          'can_pin_messages': !isChannel,
          'can_manage_topics': false,
          'can_promote_members': false,
          'can_manage_video_chats': true,
          'can_post_stories': isChannel,
          'can_edit_stories': isChannel,
          'can_delete_stories': isChannel,
          'can_manage_direct_messages': false,
          'can_manage_tags': false,
          'can_send_welcome_messages': false,
          'is_anonymous': false,
        };
    return _ToggleEditor<td.ChatAdministratorRights>(
      title: title,
      initial: base,
      fields: [
        ('can_change_info', 'right_change_info'),
        if (isChannel) ...[('can_post_messages', 'right_post'), ('can_edit_messages', 'right_edit')],
        ('can_delete_messages', 'right_delete'),
        ('can_invite_users', 'right_invite'),
        if (!isChannel) ...[('can_restrict_members', 'right_restrict'), ('can_pin_messages', 'right_pin'), ('can_manage_topics', 'right_topics')],
        ('can_manage_video_chats', 'right_video_chats'),
        ('can_post_stories', 'right_stories'),
        ('can_promote_members', 'right_promote'),
        if (!isChannel) ('is_anonymous', 'right_anonymous'),
      ],
    );
  }
}

const _permissionFields = [
  ('can_send_basic_messages', 'perm_messages'),
  ('can_send_photos', 'perm_photos'),
  ('can_send_videos', 'perm_videos'),
  ('can_send_audios', 'perm_music'),
  ('can_send_documents', 'perm_files'),
  ('can_send_voice_notes', 'perm_voice'),
  ('can_send_video_notes', 'perm_video_messages'),
  ('can_send_other_messages', 'perm_stickers'),
  ('can_send_polls', 'perm_polls'),
  ('can_add_link_previews', 'perm_links'),
  ('can_react_to_messages', 'perm_reactions'),
  ('can_invite_users', 'perm_invite'),
  ('can_pin_messages', 'perm_pin'),
  ('can_change_info', 'perm_change_info'),
  ('can_create_topics', 'perm_topics'),
];

class PermissionsEditor extends StatelessWidget {
  const PermissionsEditor({super.key, required this.title, required this.initial, this.footer});

  final String title;
  final td.ChatPermissions initial;
  final Widget? footer;

  @override
  Widget build(BuildContext context) => _ToggleEditor<td.ChatPermissions>(
        title: title,
        initial: initial.toJson(),
        fields: _permissionFields,
        footer: footer,
      );
}

/// Default permissions for all members, plus slow mode.
class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen> {
  int? _slowMode;

  @override
  void initState() {
    super.initState();
    final account = ref.read(accountProvider);
    final supergroup = account.supergroupOf(account.chats[widget.chatId]!);
    if (supergroup != null) {
      unawaited(account.supergroupInfo(supergroup.id).then((info) {
        if (mounted) setState(() => _slowMode = info.slowModeDelay);
      }).catchError((Object _) {}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final chat = ref.watch(chatProvider(widget.chatId));
    final s = context.s;
    if (chat == null) return const Scaffold();
    final slowMode = _slowMode;
    return PermissionsEditor(
      title: s.t('permissions'),
      initial: chat.permissions,
      footer: slowMode == null
          ? null
          : ListTile(
              leading: const Icon(Icons.hourglass_bottom_rounded),
              title: Text(s.t('slow_mode')),
              subtitle: Text(_durationLabel(s, slowMode)),
              onTap: () async {
                final value = await _pickSeconds(context, s, const [0, 10, 30, 60, 300, 900, 3600], slowMode);
                if (value == null || !context.mounted) return;
                final ok = await guard(context, () async {
                  await account.setSlowMode(widget.chatId, value);
                  return true;
                });
                if (ok == true && mounted) setState(() => _slowMode = value);
              },
            ),
    );
  }
}

/// Saves edited default permissions when the editor pops.
Future<void> openPermissions(BuildContext context, WidgetRef ref, int chatId) async {
  final account = ref.read(accountProvider);
  final chat = account.chats[chatId];
  if (chat == null) return;
  final permissions = await Navigator.of(context).push<td.ChatPermissions>(MaterialPageRoute(builder: (_) => PermissionsScreen(chatId: chatId)));
  if (permissions != null && context.mounted) await guard(context, () => account.setDefaultPermissions(chatId, permissions));
}

// ------------------------------------------------------------------ invite links

class InviteLinksScreen extends ConsumerStatefulWidget {
  const InviteLinksScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<InviteLinksScreen> createState() => _InviteLinksScreenState();
}

class _InviteLinksScreenState extends ConsumerState<InviteLinksScreen> {
  List<td.ChatInviteLink>? _active;
  List<td.ChatInviteLink> _revoked = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    try {
      final results = await Future.wait([account.inviteLinks(widget.chatId), account.inviteLinks(widget.chatId, revoked: true)]);
      if (mounted) {
        setState(() {
          _active = results[0];
          _revoked = results[1];
        });
      }
    } on TdException catch (error) {
      if (mounted) showToast(context, error.message);
    }
  }

  Future<void> _create() async {
    final result = await showDialog<(String, int, int, bool)>(context: context, builder: (_) => const _NewLinkDialog());
    if (result == null || !mounted) return;
    await guard(context, () => ref.read(accountProvider).createInviteLink(
          widget.chatId,
          name: result.$1,
          expiresAt: result.$2,
          memberLimit: result.$3,
          joinRequest: result.$4,
        ));
    await _load();
  }

  Future<void> _linkActions(td.ChatInviteLink link) async {
    final s = context.s;
    final account = ref.read(accountProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.copy_rounded), title: Text(s.t('copy_link')), onTap: () => Navigator.pop(context, 'copy')),
            ListTile(leading: const Icon(Icons.share_rounded), title: Text(s.t('share')), onTap: () => Navigator.pop(context, 'share')),
            if (!link.isRevoked)
              ListTile(
                leading: Icon(Icons.link_off_rounded, color: Theme.of(context).colorScheme.error),
                title: Text(s.t('revoke_link'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () => Navigator.pop(context, 'revoke'),
              )
            else
              ListTile(leading: const Icon(Icons.delete_rounded), title: Text(s.t('delete')), onTap: () => Navigator.pop(context, 'delete')),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: link.inviteLink));
        if (mounted) showToast(context, s.t('link_copied'));
      case 'share':
        await SharePlus.instance.share(ShareParams(text: link.inviteLink));
      case 'revoke':
        await guard(context, () => account.revokeInviteLink(widget.chatId, link.inviteLink));
      case 'delete':
        await guard(context, () => account.deleteRevokedInviteLink(widget.chatId, link.inviteLink));
    }
    await _load();
  }

  Widget _tile(td.ChatInviteLink link, Strings s) {
    final details = <String>[
      s.count('joined', link.memberCount),
      if (link.memberLimit > 0) s.t('link_limit', {'n': '${link.memberLimit}'}),
      if (link.pendingJoinRequestCount > 0) s.t('link_pending', {'n': '${link.pendingJoinRequestCount}'}),
      if (link.expirationDate > 0) s.t('link_expires', {'date': formatChatTime(link.expirationDate, s.locale)}),
    ];
    return ListTile(
      leading: CircleAvatar(child: Icon(link.isRevoked ? Icons.link_off_rounded : (link.isPrimary ? Icons.link_rounded : Icons.add_link_rounded))),
      title: Text(link.name.isNotEmpty ? link.name : link.inviteLink, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(details.join(' · ')),
      onTap: () => _linkActions(link),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final active = _active;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('invite_links'))),
      floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add_link_rounded), label: Text(s.t('create_link'))),
      body: active == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                for (final link in active) _tile(link, s),
                if (_revoked.isNotEmpty) ...[const Divider(), SectionHeader(s.t('revoked_links')), for (final link in _revoked) _tile(link, s)],
                const SizedBox(height: 80),
              ],
            ),
    );
  }
}

class _NewLinkDialog extends StatefulWidget {
  const _NewLinkDialog();

  @override
  State<_NewLinkDialog> createState() => _NewLinkDialogState();
}

class _NewLinkDialogState extends State<_NewLinkDialog> {
  final _name = TextEditingController();
  final _limit = TextEditingController();
  bool _requests = false;
  int _expireDays = 0;

  @override
  void dispose() {
    _name.dispose();
    _limit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return AlertDialog(
      title: Text(s.t('create_link')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _name, decoration: InputDecoration(labelText: s.t('link_name'))),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.t('link_requests')),
              value: _requests,
              onChanged: (v) => setState(() => _requests = v),
            ),
            if (!_requests)
              TextField(controller: _limit, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: s.t('link_member_limit'))),
            DropdownButtonFormField<int>(
              initialValue: _expireDays,
              decoration: InputDecoration(labelText: s.t('link_expiry')),
              items: [
                for (final days in const [0, 1, 7, 30]) DropdownMenuItem(value: days, child: Text(days == 0 ? s.t('never') : s.t('keep_days', {'n': '$days'}))),
              ],
              onChanged: (v) => setState(() => _expireDays = v ?? 0),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
        TextButton(
          onPressed: () {
            final expires = _expireDays == 0 ? 0 : DateTime.now().add(Duration(days: _expireDays)).millisecondsSinceEpoch ~/ 1000;
            final limit = (int.tryParse(_limit.text.trim()) ?? 0).clamp(0, 99999);
            Navigator.pop(context, (_name.text.trim(), expires, limit, _requests));
          },
          child: Text(s.t('create')),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ join requests

class JoinRequestsScreen extends ConsumerStatefulWidget {
  const JoinRequestsScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<JoinRequestsScreen> createState() => _JoinRequestsScreenState();
}

class _JoinRequestsScreenState extends ConsumerState<JoinRequestsScreen> {
  List<td.ChatJoinRequest>? _requests;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final result = await ref.read(accountProvider).joinRequests(widget.chatId);
      if (mounted) setState(() => _requests = result.requests);
    } on TdException catch (error) {
      if (mounted) showToast(context, error.message);
    }
  }

  Future<void> _process(td.ChatJoinRequest request, bool approve) async {
    await guard(context, () => ref.read(accountProvider).processJoinRequest(widget.chatId, request.userId, approve: approve));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final requests = _requests;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('join_requests'))),
      body: requests == null
          ? const Center(child: CircularProgressIndicator())
          : requests.isEmpty
              ? EmptyState(icon: Icons.how_to_reg_rounded, title: s.t('join_requests_empty'), subtitle: '')
              : ListView.builder(
                  itemCount: requests.length,
                  itemBuilder: (context, index) {
                    final request = requests[index];
                    return ListTile(
                      leading: UserAvatar(userId: request.userId, size: 42),
                      title: Text(account.userName(request.userId)),
                      subtitle: Text(request.bio.isNotEmpty ? request.bio : formatChatTime(request.date, s.locale), maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(tooltip: s.t('decline'), icon: const Icon(Icons.close_rounded), onPressed: () => _process(request, false)),
                          IconButton(
                            tooltip: s.t('accept'),
                            icon: Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary),
                            onPressed: () => _process(request, true),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
