import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as phone;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';

final contactsProvider = FutureProvider.autoDispose<List<int>>((ref) async {
  final account = ref.watch(accountProvider);
  final users = await account.send<td.Users>(const td.GetContacts());
  return users.userIds;
});

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key, this.pickToChat = false, this.createGroup = false, this.pickUser = false, this.pickMany = false});

  /// "New message" entry: shows new group/channel shortcuts.
  final bool pickToChat;

  /// Multi-select members, then name the group.
  final bool createGroup;

  /// Pops with the chosen [td.User].
  final bool pickUser;

  /// Pops with a list of user ids.
  final bool pickMany;

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  String _query = '';
  final Set<int> _selected = {};
  bool _importing = false;

  bool get _multi => widget.createGroup || widget.pickMany;

  Future<void> _importPhoneContacts() async {
    final s = context.s;
    final status = await phone.FlutterContacts.permissions.request(phone.PermissionType.read);
    if (status != phone.PermissionStatus.granted && status != phone.PermissionStatus.limited) {
      if (mounted) showToast(context, s.t('contacts_permission'));
      return;
    }
    setState(() => _importing = true);
    try {
      final contacts = await phone.FlutterContacts.getAll(properties: {phone.ContactProperty.name, phone.ContactProperty.phone});
      final imported = <td.ImportedContact>[
        for (final contact in contacts)
          for (final number in contact.phones)
            td.ImportedContact(
              phoneNumber: number.number,
              firstName: contact.name?.first ?? contact.displayName ?? '',
              lastName: contact.name?.last ?? '',
              note: null,
            ),
      ];
      if (!mounted) return;
      final account = ref.read(accountProvider);
      for (var i = 0; i < imported.length; i += 500) {
        final batch = imported.sublist(i, (i + 500).clamp(0, imported.length));
        await guard(context, () => account.send<td.ImportedContacts>(td.ImportContacts(contacts: batch)));
        if (!mounted) return;
      }
      ref.invalidate(contactsProvider);
      showToast(context, s.t('contacts_synced'));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _onUserTap(td.User user) async {
    if (_multi) {
      setState(() => _selected.contains(user.id) ? _selected.remove(user.id) : _selected.add(user.id));
      return;
    }
    if (widget.pickUser) {
      Navigator.pop(context, user);
      return;
    }
    final account = ref.read(accountProvider);
    final chat = await guard(context, () => account.openPrivateChat(user.id));
    if (chat == null || !mounted) return;
    Navigator.pop(context);
    openChat(context, chat.id);
  }

  Future<void> _next() async {
    if (widget.pickMany) {
      Navigator.pop(context, _selected.toList());
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NewGroupScreen(memberIds: _selected.toList())));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ids = ref.watch(contactsProvider);
    final account = ref.watch(accountProvider);
    ref.watch(usersRevisionProvider);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          style: const TextStyle(color: Colors.white),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: s.t(widget.createGroup ? 'add_members' : 'search_contacts'),
            hintStyle: const TextStyle(color: Colors.white70),
            border: InputBorder.none,
          ),
          onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
        ),
        actions: [
          if (!_multi && !widget.pickUser)
            IconButton(
              tooltip: s.t('sync_contacts'),
              icon: _importing
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.sync_rounded),
              onPressed: _importing ? null : _importPhoneContacts,
            ),
        ],
      ),
      floatingActionButton: _multi && (_selected.isNotEmpty || widget.createGroup)
          ? FloatingActionButton(onPressed: _next, child: const Icon(Icons.arrow_forward_rounded))
          : null,
      body: ids.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(errorText(context, error))),
        data: (userIds) {
          final users = userIds.map((id) => account.users[id]).whereType<td.User>().where((u) {
            if (_query.isEmpty) return true;
            final name = '${u.firstName} ${u.lastName}'.toLowerCase();
            final username = u.usernames?.activeUsernames.join(' ').toLowerCase() ?? '';
            return name.contains(_query) || username.contains(_query) || u.phoneNumber.contains(_query);
          }).toList()
            ..sort((a, b) {
              final online = (isOnline(b) ? 1 : 0) - (isOnline(a) ? 1 : 0);
              return online != 0 ? online : a.firstName.toLowerCase().compareTo(b.firstName.toLowerCase());
            });
          return ListView(
            children: [
              if (widget.pickToChat && _query.isEmpty) ...[
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.group_add_rounded)),
                  title: Text(s.t('new_group')),
                  onTap: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute<void>(builder: (_) => const ContactsScreen(createGroup: true)),
                  ),
                ),
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.campaign_rounded)),
                  title: Text(s.t('new_channel')),
                  onTap: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const NewChannelScreen())),
                ),
                const Divider(),
              ],
              if (users.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    children: [
                      Text(s.t('no_contacts'), textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      if (!_multi)
                        OutlinedButton.icon(onPressed: _importPhoneContacts, icon: const Icon(Icons.sync_rounded), label: Text(s.t('sync_contacts'))),
                    ],
                  ),
                ),
              for (final user in users)
                ListTile(
                  leading: UserAvatar(userId: user.id, size: 46),
                  title: Text('${user.firstName} ${user.lastName}'.trim(), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    formatUserStatus(user, s),
                    style: TextStyle(color: isOnline(user) ? Theme.of(context).colorScheme.primary : null),
                  ),
                  trailing: _multi
                      ? Checkbox(value: _selected.contains(user.id), onChanged: (_) => _onUserTap(user))
                      : null,
                  onTap: () => _onUserTap(user),
                ),
            ],
          );
        },
      ),
    );
  }
}

class NewGroupScreen extends ConsumerStatefulWidget {
  const NewGroupScreen({super.key, required this.memberIds});

  final List<int> memberIds;

  @override
  ConsumerState<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends ConsumerState<NewGroupScreen> {
  final _title = TextEditingController();
  String? _photoPath;
  bool _creating = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    setState(() => _creating = true);
    final account = ref.read(accountProvider);
    final chatId = await guard(context, () async {
      final created = await account.send<td.CreatedBasicGroupChat>(
        td.CreateNewBasicGroupChat(userIds: widget.memberIds, title: title, messageAutoDeleteTime: 0),
      );
      if (_photoPath != null) {
        await account.send<td.Ok>(td.SetChatPhoto(
          chatId: created.chatId,
          photo: td.InputChatPhotoStatic(photo: td.InputFileLocal(path: _photoPath!)),
        ));
      }
      return created.chatId;
    });
    if (!mounted) return;
    setState(() => _creating = false);
    if (chatId != null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      openChat(context, chatId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('new_group'))),
      floatingActionButton: FloatingActionButton(
        onPressed: _creating ? null : _create,
        child: _creating
            ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : const Icon(Icons.check_rounded),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              _PhotoPicker(path: _photoPath, onPicked: (path) => setState(() => _photoPath = path)),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _title,
                  autofocus: true,
                  decoration: InputDecoration(labelText: s.t('group_name')),
                  onSubmitted: (_) => _create(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SectionHeader(s.count('members', widget.memberIds.length + 1)),
          for (final id in widget.memberIds) ListTile(leading: UserAvatar(userId: id, size: 40), title: Text(ref.watch(accountProvider).userName(id))),
        ],
      ),
    );
  }
}

class NewChannelScreen extends ConsumerStatefulWidget {
  const NewChannelScreen({super.key});

  @override
  ConsumerState<NewChannelScreen> createState() => _NewChannelScreenState();
}

class _NewChannelScreenState extends ConsumerState<NewChannelScreen> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _username = TextEditingController();
  String? _photoPath;
  bool _creating = false;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _username.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    setState(() => _creating = true);
    final account = ref.read(accountProvider);
    final chatId = await guard(context, () async {
      final chat = await account.send<td.Chat>(td.CreateNewSupergroupChat(
        title: title,
        isForum: false,
        isChannel: true,
        description: _description.text.trim(),
        location: null,
        messageAutoDeleteTime: 0,
        forImport: false,
      ));
      if (_photoPath != null) {
        await account.send<td.Ok>(td.SetChatPhoto(
          chatId: chat.id,
          photo: td.InputChatPhotoStatic(photo: td.InputFileLocal(path: _photoPath!)),
        ));
      }
      final username = _username.text.trim();
      if (username.isNotEmpty && chat.type is td.ChatTypeSupergroup) {
        await account.send<td.Ok>(td.SetSupergroupUsername(
          supergroupId: (chat.type as td.ChatTypeSupergroup).supergroupId,
          username: username,
        ));
      }
      return chat.id;
    });
    if (!mounted) return;
    setState(() => _creating = false);
    if (chatId != null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      openChat(context, chatId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('new_channel'))),
      floatingActionButton: FloatingActionButton(
        onPressed: _creating ? null : _create,
        child: _creating
            ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : const Icon(Icons.check_rounded),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              _PhotoPicker(path: _photoPath, onPicked: (path) => setState(() => _photoPath = path)),
              const SizedBox(width: 16),
              Expanded(child: TextField(controller: _title, autofocus: true, decoration: InputDecoration(labelText: s.t('channel_name')))),
            ],
          ),
          const SizedBox(height: 16),
          TextField(controller: _description, minLines: 2, maxLines: 4, decoration: InputDecoration(labelText: s.t('description'))),
          const SizedBox(height: 16),
          TextField(
            controller: _username,
            decoration: InputDecoration(labelText: s.t('public_link'), prefixText: 't.me/', helperText: s.t('public_link_hint')),
          ),
        ],
      ),
    );
  }
}

class _PhotoPicker extends StatelessWidget {
  const _PhotoPicker({required this.path, required this.onPicked});

  final String? path;
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () async {
          final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 92, maxWidth: 1280);
          if (file != null) onPicked(file.path);
        },
        child: CircleAvatar(
          radius: 34,
          backgroundColor: Theme.of(context).colorScheme.primary,
          backgroundImage: path == null ? null : ResizeImage(FileImage(File(path!)), width: 200),
          child: path == null ? const Icon(Icons.add_a_photo_rounded, color: Colors.white) : null,
        ),
      );
}
