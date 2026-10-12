import 'dart:async';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'message_content.dart';

// ------------------------------------------------------------------ mentions

/// Members matching the "@query" being typed.
class MentionSuggestions extends ConsumerWidget {
  const MentionSuggestions({super.key, required this.members, required this.onPick});

  final List<td.ChatMember> members;
  final void Function(td.User user) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final users = [
      for (final member in members)
        if (member.memberId case td.MessageSenderUser(:final userId)) account.users[userId],
    ].whereType<td.User>().toList();
    if (users.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 200),
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: users.length,
        itemBuilder: (context, index) {
          final user = users[index];
          final username = user.usernames?.activeUsernames.firstOrNull;
          return ListTile(
            dense: true,
            leading: UserAvatar(userId: user.id, size: 34, showOnline: false),
            title: Text('${user.firstName} ${user.lastName}'.trim(), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: username == null ? null : Text('@$username'),
            onTap: () => onPick(user),
          );
        },
      ),
    );
  }
}

// ------------------------------------------------------------------ inline bots

/// Every InlineQueryResult subclass has an id, but the base class does not expose it.
String inlineResultId(td.InlineQueryResult result) => switch (result) {
      td.InlineQueryResultArticle(:final id) ||
      td.InlineQueryResultContact(:final id) ||
      td.InlineQueryResultLocation(:final id) ||
      td.InlineQueryResultVenue(:final id) ||
      td.InlineQueryResultGame(:final id) ||
      td.InlineQueryResultAnimation(:final id) ||
      td.InlineQueryResultAudio(:final id) ||
      td.InlineQueryResultDocument(:final id) ||
      td.InlineQueryResultPhoto(:final id) ||
      td.InlineQueryResultSticker(:final id) ||
      td.InlineQueryResultVideo(:final id) ||
      td.InlineQueryResultVoiceNote(:final id) =>
        id,
      _ => '',
    };

/// Results of an inline bot query ("@gif cats"), shown above the input.
class InlineResultsPanel extends StatelessWidget {
  const InlineResultsPanel({super.key, required this.results, required this.onPick, required this.onLoadMore});

  final td.InlineQueryResults results;
  final void Function(String resultId) onPick;
  final VoidCallback onLoadMore;

  static bool _isMedia(td.InlineQueryResult r) =>
      r is td.InlineQueryResultPhoto || r is td.InlineQueryResultAnimation || r is td.InlineQueryResultSticker ||
      r is td.InlineQueryResultVideo;

  @override
  Widget build(BuildContext context) {
    final items = results.results;
    String idOf(td.InlineQueryResult r) => inlineResultId(r);
    if (items.isEmpty) return const SizedBox.shrink();
    final media = items.where(_isMedia).length > items.length / 2;
    final list = NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 300 && results.nextOffset.isNotEmpty) onLoadMore();
        return false;
      },
      child: media
          ? GridView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(4),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 1, mainAxisSpacing: 4),
              itemCount: items.length,
              itemBuilder: (context, index) => InkWell(onTap: () => onPick(idOf(items[index])), child: _InlineThumb(result: items[index])),
            )
          : ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: items.length,
              itemBuilder: (context, index) {
                final r = items[index];
                final (title, subtitle) = _texts(r);
                return ListTile(
                  dense: true,
                  leading: SizedBox.square(dimension: 44, child: ClipRRect(borderRadius: BorderRadius.circular(6), child: _InlineThumb(result: r))),
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: subtitle.isEmpty ? null : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => onPick(idOf(r)),
                );
              },
            ),
    );
    return SizedBox(height: media ? 110 : 220, child: list);
  }

  static (String, String) _texts(td.InlineQueryResult r) => switch (r) {
        td.InlineQueryResultArticle(:final title, :final description) => (title, description),
        td.InlineQueryResultDocument(:final title, :final description) => (title, description),
        td.InlineQueryResultPhoto(:final title, :final description) => (title, description),
        td.InlineQueryResultVideo(:final title, :final description) => (title, description),
        td.InlineQueryResultAudio(:final audio) => (audio.title.isEmpty ? audio.fileName : audio.title, audio.performer),
        td.InlineQueryResultVoiceNote(:final title) => (title, ''),
        td.InlineQueryResultLocation(:final title) => (title, ''),
        td.InlineQueryResultVenue(:final venue) => (venue.title, venue.address),
        td.InlineQueryResultContact(:final contact) => ('${contact.firstName} ${contact.lastName}'.trim(), contact.phoneNumber),
        td.InlineQueryResultGame(:final game) => (game.title, game.description),
        td.InlineQueryResultAnimation(:final title) => (title, ''),
        _ => ('', ''),
      };
}

class _InlineThumb extends StatelessWidget {
  const _InlineThumb({required this.result});

  final td.InlineQueryResult result;

  Widget _thumb(td.Thumbnail? thumbnail, {td.Minithumbnail? mini}) {
    if (thumbnail == null) return const ColoredBox(color: Colors.black12, child: Center(child: Icon(Icons.article_rounded)));
    if (thumbnail.format is td.ThumbnailFormatMpeg4) {
      return _AutoplayThumb(file: thumbnail.file, fallback: const ColoredBox(color: Colors.black12));
    }
    return TdImage(file: thumbnail.file, minithumbnail: mini, fit: BoxFit.cover);
  }

  @override
  Widget build(BuildContext context) => switch (result) {
        td.InlineQueryResultPhoto(:final photo) => bestPhotoSize(photo, target: 320) == null
            ? const SizedBox.shrink()
            : TdImage(file: bestPhotoSize(photo, target: 320)!.photo, minithumbnail: photo.minithumbnail, fit: BoxFit.cover),
        td.InlineQueryResultAnimation(:final animation) => _thumb(animation.thumbnail, mini: animation.minithumbnail),
        td.InlineQueryResultVideo(:final video) => _thumb(video.thumbnail, mini: video.minithumbnail),
        td.InlineQueryResultSticker(:final sticker) => _thumb(sticker.thumbnail),
        td.InlineQueryResultArticle(:final thumbnail) => _thumb(thumbnail),
        td.InlineQueryResultDocument(:final document) => _thumb(document.thumbnail, mini: document.minithumbnail),
        td.InlineQueryResultContact(:final thumbnail) => _thumb(thumbnail),
        td.InlineQueryResultLocation(:final thumbnail) => _thumb(thumbnail),
        td.InlineQueryResultVenue(:final thumbnail) => _thumb(thumbnail),
        _ => const ColoredBox(color: Colors.black12),
      };
}

/// Downloads a small MPEG4 preview and loops it.
class _AutoplayThumb extends ConsumerWidget {
  const _AutoplayThumb({required this.file, required this.fallback});

  final td.File file;
  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(fileProvider(file.id)).value ?? file;
    if (!current.local.isDownloadingCompleted || current.local.path.isEmpty) return fallback;
    return ClipRect(child: LoopingVideo(key: ValueKey(current.local.path), path: current.local.path, fallback: fallback));
  }
}

// ------------------------------------------------------------------ emoji / stickers / GIFs

/// Bottom panel replacing the keyboard: emoji, sticker sets and saved/searched GIFs.
class MediaPanel extends ConsumerStatefulWidget {
  const MediaPanel({
    super.key,
    required this.controller,
    required this.chatId,
    required this.onSticker,
    required this.onAnimation,
    required this.onInlineResult,
  });

  final TextEditingController controller;
  final int chatId;
  final void Function(td.Sticker sticker) onSticker;
  final void Function(td.Animation animation) onAnimation;
  final void Function(int queryId, String resultId) onInlineResult;

  @override
  ConsumerState<MediaPanel> createState() => _MediaPanelState();
}

class _MediaPanelState extends ConsumerState<MediaPanel> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = context.s;
    return SizedBox(
      height: 300,
      child: Column(
        children: [
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                EmojiPicker(
                  textEditingController: widget.controller,
                  config: Config(
                    height: 260,
                    emojiViewConfig: EmojiViewConfig(backgroundColor: theme.colorScheme.surface, emojiSizeMax: 30),
                    categoryViewConfig: CategoryViewConfig(
                      backgroundColor: theme.colorScheme.surface,
                      indicatorColor: theme.colorScheme.primary,
                      iconColorSelected: theme.colorScheme.primary,
                    ),
                    bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
                    searchViewConfig: SearchViewConfig(backgroundColor: theme.colorScheme.surface),
                  ),
                ),
                _StickersTab(onSticker: widget.onSticker),
                _GifsTab(chatId: widget.chatId, onAnimation: widget.onAnimation, onInlineResult: widget.onInlineResult),
              ],
            ),
          ),
          TabBar(
            controller: _tabs,
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: theme.hintColor,
            indicatorColor: theme.colorScheme.primary,
            tabs: [
              Tab(height: 40, text: s.t('emoji')),
              Tab(height: 40, text: s.t('stickers')),
              const Tab(height: 40, text: 'GIF'),
            ],
          ),
        ],
      ),
    );
  }
}

class _StickersTab extends ConsumerStatefulWidget {
  const _StickersTab({required this.onSticker});

  final void Function(td.Sticker sticker) onSticker;

  @override
  ConsumerState<_StickersTab> createState() => _StickersTabState();
}

class _StickersTabState extends ConsumerState<_StickersTab> with AutomaticKeepAliveClientMixin {
  List<td.StickerSetInfo> _sets = const [];
  List<td.Sticker> _recent = const [];
  List<td.Sticker> _favorite = const [];
  final Map<int, List<td.Sticker>> _setStickers = {};

  /// -1 = recent, -2 = favorites, otherwise a sticker set id.
  int _selected = -1;
  bool _loaded = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    try {
      final results = await Future.wait([account.installedStickerSets(), account.recentStickers(), account.favoriteStickers()]);
      if (!mounted) return;
      setState(() {
        _sets = results[0] as List<td.StickerSetInfo>;
        _recent = results[1] as List<td.Sticker>;
        _favorite = results[2] as List<td.Sticker>;
        _loaded = true;
        if (_recent.isEmpty) _selected = _favorite.isNotEmpty ? -2 : (_sets.isNotEmpty ? _sets.first.id : -1);
      });
      if (_selected > 0) await _openSet(_selected);
    } on TdException catch (error) {
      debugPrint('stickers unavailable: $error');
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _openSet(int setId) async {
    setState(() => _selected = setId);
    if (_setStickers.containsKey(setId)) return;
    try {
      final set = await ref.read(accountProvider).stickerSet(setId);
      if (mounted) setState(() => _setStickers[setId] = set.stickers);
    } on TdException catch (error) {
      debugPrint('sticker set $setId failed: $error');
    }
  }

  List<td.Sticker> get _current => switch (_selected) {
        -1 => _recent,
        -2 => _favorite,
        _ => _setStickers[_selected] ?? const [],
      };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    final primary = Theme.of(context).colorScheme.primary;
    Widget tab(int id, Widget icon) => InkWell(
          onTap: () => id > 0 ? _openSet(id) : setState(() => _selected = id),
          child: Container(
            width: 44,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: _selected == id ? primary : Colors.transparent, width: 2)),
            ),
            child: icon,
          ),
        );
    final stickers = _current;
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              tab(-1, const Icon(Icons.access_time_rounded)),
              if (_favorite.isNotEmpty) tab(-2, const Icon(Icons.star_rounded)),
              for (final set in _sets)
                tab(
                  set.id,
                  set.covers.isNotEmpty ? _StickerThumb(sticker: set.covers.first) : Center(child: Text(set.title.characters.first)),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: stickers.isEmpty
              ? Center(child: Text(context.t('nothing_here'), style: TextStyle(color: Theme.of(context).hintColor)))
              : GridView.builder(
                  padding: const EdgeInsets.all(6),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 80, mainAxisSpacing: 4, crossAxisSpacing: 4),
                  itemCount: stickers.length,
                  itemBuilder: (context, index) => InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => widget.onSticker(stickers[index]),
                    child: _StickerThumb(sticker: stickers[index]),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Static preview of a sticker (thumbnail for animated ones keeps the grid light).
class _StickerThumb extends StatelessWidget {
  const _StickerThumb({required this.sticker});

  final td.Sticker sticker;

  @override
  Widget build(BuildContext context) {
    if (sticker.format is td.StickerFormatWebp) return TdImage(file: sticker.sticker, fit: BoxFit.contain);
    final thumb = sticker.thumbnail;
    if (thumb != null && thumb.format is! td.ThumbnailFormatTgs && thumb.format is! td.ThumbnailFormatWebm) {
      return TdImage(file: thumb.file, fit: BoxFit.contain);
    }
    return Center(child: Text(sticker.emoji, style: const TextStyle(fontSize: 34)));
  }
}

class _GifsTab extends ConsumerStatefulWidget {
  const _GifsTab({required this.chatId, required this.onAnimation, required this.onInlineResult});

  final int chatId;
  final void Function(td.Animation animation) onAnimation;
  final void Function(int queryId, String resultId) onInlineResult;

  @override
  ConsumerState<_GifsTab> createState() => _GifsTabState();
}

class _GifsTabState extends ConsumerState<_GifsTab> with AutomaticKeepAliveClientMixin {
  List<td.Animation> _saved = const [];
  td.InlineQueryResults? _search;
  td.User? _gifBot;
  Timer? _debounce;
  final _query = TextEditingController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSaved());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    try {
      final saved = await ref.read(accountProvider).savedAnimations();
      if (mounted) setState(() => _saved = saved);
    } on TdException catch (error) {
      debugPrint('saved GIFs unavailable: $error');
    }
  }

  void _onQuery(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => unawaited(_runSearch(text.trim())));
  }

  Future<void> _runSearch(String query) async {
    if (query.isEmpty) {
      setState(() => _search = null);
      return;
    }
    final account = ref.read(accountProvider);
    final username = account.options['animation_search_bot_username'];
    final botName = username is td.OptionValueString && username.value.isNotEmpty ? username.value : 'gif';
    _gifBot ??= await account.inlineBot(botName);
    final bot = _gifBot;
    if (bot == null) return;
    try {
      final results = await account.inlineResults(bot.id, widget.chatId, query);
      if (mounted && _query.text.trim() == query) setState(() => _search = results);
    } on TdException catch (error) {
      debugPrint('GIF search failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = context.s;
    final search = _search;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: TextField(
            controller: _query,
            onChanged: _onQuery,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: s.t('search_gifs'),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
            ),
          ),
        ),
        Expanded(
          child: search != null
              ? GridView.builder(
                  padding: const EdgeInsets.all(4),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, mainAxisSpacing: 4, crossAxisSpacing: 4),
                  itemCount: search.results.length,
                  itemBuilder: (context, index) {
                    final result = search.results[index];
                    return InkWell(
                      onTap: () => widget.onInlineResult(search.inlineQueryId, inlineResultId(result)),
                      child: ClipRRect(borderRadius: BorderRadius.circular(6), child: _InlineThumb(result: result)),
                    );
                  },
                )
              : _saved.isEmpty
                  ? Center(child: Text(s.t('nothing_here'), style: TextStyle(color: Theme.of(context).hintColor)))
                  : GridView.builder(
                      padding: const EdgeInsets.all(4),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, mainAxisSpacing: 4, crossAxisSpacing: 4),
                      itemCount: _saved.length,
                      itemBuilder: (context, index) {
                        final animation = _saved[index];
                        final thumb = animation.thumbnail;
                        return InkWell(
                          onTap: () => widget.onAnimation(animation),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: thumb != null && thumb.format is! td.ThumbnailFormatMpeg4
                                ? TdImage(file: thumb.file, minithumbnail: animation.minithumbnail, fit: BoxFit.cover)
                                : _AutoplayThumb(file: animation.animation, fallback: const ColoredBox(color: Colors.black12)),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
