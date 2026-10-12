import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../chat/message_content.dart';

// ------------------------------------------------------------------ proxy

class ProxyScreen extends ConsumerStatefulWidget {
  const ProxyScreen({super.key});

  @override
  ConsumerState<ProxyScreen> createState() => _ProxyScreenState();
}

class _ProxyScreenState extends ConsumerState<ProxyScreen> {
  List<td.AddedProxy>? _proxies;
  final Map<int, int?> _pings = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    try {
      final proxies = await account.proxies();
      if (!mounted) return;
      setState(() => _proxies = proxies);
      for (final proxy in proxies) {
        unawaited(account.pingProxy(proxy.proxy).then((ms) {
          if (mounted) setState(() => _pings[proxy.id] = ms);
        }));
      }
    } on TdException catch (error) {
      if (mounted) showToast(context, error.message);
    }
  }

  Future<void> _add() async {
    final proxy = await showDialog<td.Proxy>(context: context, builder: (_) => const _ProxyDialog());
    if (proxy == null || !mounted) return;
    await guard(context, () => ref.read(accountProvider).addProxy(proxy));
    await _load();
  }

  Future<void> _pasteLink() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final proxy = parseProxyLink(data?.text ?? '');
    if (!mounted) return;
    if (proxy == null) {
      showToast(context, context.t('proxy_link_invalid'));
      return;
    }
    await guard(context, () => ref.read(accountProvider).addProxy(proxy));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final proxies = _proxies;
    final anyEnabled = proxies?.any((p) => p.isEnabled) ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('proxy')),
        actions: [IconButton(tooltip: s.t('proxy_paste'), icon: const Icon(Icons.content_paste_rounded), onPressed: _pasteLink)],
      ),
      floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.add_rounded)),
      body: proxies == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  title: Text(s.t('proxy_use')),
                  subtitle: Text(s.t('proxy_hint')),
                  value: anyEnabled,
                  onChanged: proxies.isEmpty
                      ? null
                      : (on) async {
                          await guard(context, () => on ? account.enableProxy(proxies.first.id) : account.disableProxy());
                          await _load();
                        },
                ),
                const Divider(),
                if (proxies.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(s.t('proxy_empty'), textAlign: TextAlign.center)),
                for (final proxy in proxies)
                  ListTile(
                    leading: Icon(
                      proxy.isEnabled ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                      color: proxy.isEnabled ? Theme.of(context).colorScheme.primary : null,
                    ),
                    title: Text('${proxy.proxy.server}:${proxy.proxy.port}'),
                    subtitle: Text([
                      switch (proxy.proxy.type) {
                        td.ProxyTypeMtproto() => 'MTProto',
                        td.ProxyTypeSocks5() => 'SOCKS5',
                        td.ProxyTypeHttp() => 'HTTP',
                        _ => '',
                      },
                      if (_pings.containsKey(proxy.id)) _pings[proxy.id] == null ? s.t('proxy_unavailable') : '${_pings[proxy.id]} ms',
                    ].join(' · ')),
                    onTap: () async {
                      await guard(context, () => account.enableProxy(proxy.id));
                      await _load();
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () async {
                        await guard(context, () => account.removeProxy(proxy.id));
                        await _load();
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ProxyDialog extends StatefulWidget {
  const _ProxyDialog();

  @override
  State<_ProxyDialog> createState() => _ProxyDialogState();
}

class _ProxyDialogState extends State<_ProxyDialog> {
  String _type = 'mtproto';
  final _server = TextEditingController();
  final _port = TextEditingController();
  final _secret = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    for (final c in [_server, _port, _secret, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return AlertDialog(
      title: Text(s.t('proxy_add')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'mtproto', label: Text('MTProto')),
                ButtonSegment(value: 'socks5', label: Text('SOCKS5')),
                ButtonSegment(value: 'http', label: Text('HTTP')),
              ],
              selected: {_type},
              onSelectionChanged: (v) => setState(() => _type = v.first),
            ),
            TextField(controller: _server, decoration: InputDecoration(labelText: s.t('proxy_server'))),
            TextField(controller: _port, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: s.t('proxy_port'))),
            if (_type == 'mtproto')
              TextField(controller: _secret, decoration: InputDecoration(labelText: s.t('proxy_secret')))
            else ...[
              TextField(controller: _user, decoration: InputDecoration(labelText: s.t('proxy_username'))),
              TextField(controller: _password, obscureText: true, decoration: InputDecoration(labelText: s.t('password'))),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
        TextButton(
          onPressed: () {
            final port = int.tryParse(_port.text.trim()) ?? 0;
            final server = _server.text.trim();
            if (server.isEmpty || port <= 0 || port > 65535 || (_type == 'mtproto' && _secret.text.trim().isEmpty)) {
              showToast(context, s.t('proxy_invalid'));
              return;
            }
            final type = switch (_type) {
              'mtproto' => td.ProxyTypeMtproto(secret: _secret.text.trim()) as td.ProxyType,
              'socks5' => td.ProxyTypeSocks5(username: _user.text.trim(), password: _password.text),
              _ => td.ProxyTypeHttp(username: _user.text.trim(), password: _password.text, httpOnly: false),
            };
            Navigator.pop(context, td.Proxy(server: server, port: port, type: type));
          },
          child: Text(s.t('add')),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ data & storage

class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  td.StorageStatisticsFast? _stats;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final stats = await ref.read(accountProvider).storageStats();
      if (mounted) setState(() => _stats = stats);
    } on TdException catch (error) {
      if (mounted) showToast(context, error.message);
    }
  }

  Future<void> _clear() async {
    final s = context.s;
    final ok = await confirm(context, title: s.t('clear_cache'), message: s.t('clear_cache_confirm'), destructive: true);
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    await guard(context, () => ref.read(accountProvider).clearCache());
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
    if (mounted) showToast(context, s.t('cache_cleared'));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final stats = _stats;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('data_storage'))),
      body: ListView(
        children: [
          SectionHeader(s.t('storage_usage')),
          if (stats == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else ...[
            ListTile(leading: const Icon(Icons.perm_media_rounded), title: Text(s.t('storage_media')), trailing: Text('${formatFileSize(stats.filesSize)} · ${stats.fileCount}')),
            ListTile(leading: const Icon(Icons.storage_rounded), title: Text(s.t('storage_database')), trailing: Text(formatFileSize(stats.databaseSize))),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: _busy || stats.filesSize == 0 ? null : _clear,
                icon: _busy ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cleaning_services_rounded),
                label: Text(s.t('clear_cache')),
              ),
            ),
          ],
          const Divider(),
          SectionHeader(s.t('keep_media')),
          RadioGroup<int>(
            groupValue: settings.keepMediaDays,
            onChanged: (v) {
              if (v != null) notifier.setKeepMediaDays(v);
            },
            child: Column(
              children: [
                for (final days in const [3, 7, 30, 0])
                  RadioListTile<int>(value: days, title: Text(days == 0 ? s.t('keep_forever') : s.t('keep_days', {'n': '$days'}))),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(s.t('keep_media_hint'), style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
          ),
          const Divider(),
          SectionHeader(s.t('auto_download')),
          SwitchListTile(
            title: Text(s.t('auto_download_photos')),
            value: settings.autoDownloadPhotos,
            onChanged: notifier.setAutoDownloadPhotos,
          ),
          SwitchListTile(
            title: Text(s.t('autoplay_gifs')),
            value: settings.autoplayGifs,
            onChanged: notifier.setAutoplayGifs,
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ two-step verification

class TwoStepScreen extends ConsumerStatefulWidget {
  const TwoStepScreen({super.key});

  @override
  ConsumerState<TwoStepScreen> createState() => _TwoStepScreenState();
}

class _TwoStepScreenState extends ConsumerState<TwoStepScreen> {
  td.PasswordState? _state;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final state = await ref.read(accountProvider).passwordState();
      if (mounted) setState(() => _state = state);
    } on TdException catch (error) {
      if (mounted) showToast(context, errorTextFromCode(context, error.message));
    }
  }

  Future<void> _afterChange(td.PasswordState state) async {
    setState(() => _state = state);
    final pending = state.recoveryEmailAddressCodeInfo;
    if (pending == null || !mounted) return;
    final code = await _prompt(context.t('email_code_title'), context.t('email_code_sent', {'email': pending.emailAddressPattern}));
    if (code == null || !mounted) return;
    final confirmed = await guard(context, () => ref.read(accountProvider).confirmRecoveryEmail(code));
    if (confirmed != null && mounted) setState(() => _state = confirmed);
  }

  Future<String?> _prompt(String title, String message, {bool obscure = false}) async {
    final controller = TextEditingController();
    final s = context.s;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.isNotEmpty) Text(message),
            TextField(controller: controller, autofocus: true, obscureText: obscure),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(s.t('ok'))),
        ],
      ),
    );
    controller.dispose();
    return result == null || result.isEmpty ? null : result;
  }

  Future<void> _setOrChange() async {
    final has = _state?.hasPassword ?? false;
    final result = await Navigator.of(context).push<(String, String, String, String)>(
      MaterialPageRoute(builder: (_) => _PasswordForm(askOld: has, askEmail: !(_state?.hasRecoveryEmailAddress ?? false))),
    );
    if (result == null || !mounted) return;
    final state = await guard(
      context,
      () => ref.read(accountProvider).setPassword(oldPassword: result.$1, newPassword: result.$2, hint: result.$3, recoveryEmail: result.$4),
    );
    if (state != null && mounted) await _afterChange(state);
  }

  Future<void> _remove() async {
    final s = context.s;
    final old = await _prompt(s.t('two_step_current'), '', obscure: true);
    if (old == null || !mounted) return;
    final ok = await confirm(context, title: s.t('two_step_disable'), message: s.t('two_step_disable_confirm'), destructive: true);
    if (!ok || !mounted) return;
    final state = await guard(context, () => ref.read(accountProvider).setPassword(oldPassword: old, newPassword: ''));
    if (state != null && mounted) setState(() => _state = state);
  }

  Future<void> _changeEmail() async {
    final s = context.s;
    final password = await _prompt(s.t('two_step_current'), '', obscure: true);
    if (password == null || !mounted) return;
    final email = await _prompt(s.t('recovery_email'), '');
    if (email == null || !mounted) return;
    final state = await guard(context, () => ref.read(accountProvider).setRecoveryEmail(password, email.trim()));
    if (state != null && mounted) await _afterChange(state);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final state = _state;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('two_step'))),
      body: state == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Icon(state.hasPassword ? Icons.verified_user_rounded : Icons.shield_outlined, size: 72, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 12),
                      Text(s.t(state.hasPassword ? 'two_step_on' : 'two_step_off'), textAlign: TextAlign.center),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.password_rounded),
                  title: Text(s.t(state.hasPassword ? 'two_step_change' : 'two_step_set')),
                  onTap: _setOrChange,
                ),
                if (state.hasPassword) ...[
                  ListTile(
                    leading: const Icon(Icons.email_rounded),
                    title: Text(s.t(state.hasRecoveryEmailAddress ? 'recovery_email_change' : 'recovery_email_set')),
                    onTap: _changeEmail,
                  ),
                  ListTile(
                    leading: Icon(Icons.no_encryption_rounded, color: Theme.of(context).colorScheme.error),
                    title: Text(s.t('two_step_disable'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    onTap: _remove,
                  ),
                ],
              ],
            ),
    );
  }
}

class _PasswordForm extends StatefulWidget {
  const _PasswordForm({required this.askOld, required this.askEmail});

  final bool askOld;
  final bool askEmail;

  @override
  State<_PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends State<_PasswordForm> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _repeat = TextEditingController();
  final _hint = TextEditingController();
  final _email = TextEditingController();
  String? _error;

  @override
  void dispose() {
    for (final c in [_old, _new, _repeat, _hint, _email]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final s = context.s;
    if (_new.text.length < 4) {
      setState(() => _error = s.t('password_too_short'));
    } else if (_new.text != _repeat.text) {
      setState(() => _error = s.t('passwords_mismatch'));
    } else if (_hint.text.trim() == _new.text) {
      setState(() => _error = s.t('hint_equals_password'));
    } else {
      Navigator.pop(context, (_old.text, _new.text, _hint.text.trim(), _email.text.trim()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('two_step'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.askOld)
            TextField(controller: _old, obscureText: true, decoration: InputDecoration(labelText: s.t('two_step_current'))),
          TextField(controller: _new, obscureText: true, decoration: InputDecoration(labelText: s.t('two_step_new'))),
          TextField(controller: _repeat, obscureText: true, decoration: InputDecoration(labelText: s.t('two_step_repeat'))),
          TextField(controller: _hint, decoration: InputDecoration(labelText: s.t('two_step_hint'))),
          if (widget.askEmail)
            TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: InputDecoration(labelText: s.t('recovery_email'))),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 20),
          FilledButton(onPressed: _submit, child: Text(s.t('save'))),
        ],
      ),
    );
  }
}
