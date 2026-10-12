import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import 'td_native.dart';

/// Error returned by TDLib for a request.
class TdException implements Exception {
  TdException(this.code, this.message, this.request);

  final int code;
  final String message;
  final String request;

  bool get isFloodWait => code == 429 || message.startsWith('FLOOD_WAIT');

  @override
  String toString() => 'TdException($code, $message) for $request';
}

/// Process-wide receive loop: one background isolate polls `td_receive` and forwards raw JSON
/// to the main isolate, where it is routed to the right [TdClient] by `@client_id`.
class TdReceiver {
  TdReceiver._();

  static final TdReceiver instance = TdReceiver._();

  final Map<int, TdClient> _clients = {};
  ReceivePort? _port;
  Isolate? _isolate;

  Future<void> _ensureStarted() async {
    if (_isolate != null) return;
    final port = ReceivePort();
    _port = port;
    port.listen(_dispatch);
    _isolate = await Isolate.spawn(_receiveLoop, port.sendPort, debugName: 'tdlib-receive');
  }

  void _register(TdClient client) => _clients[client.id] = client;

  void _unregister(TdClient client) => _clients.remove(client.id);

  void _dispatch(Object? message) {
    if (message is! String) return;
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(message) as Map<String, dynamic>;
    } on FormatException catch (error) {
      debugPrint('tdlib: malformed json: $error');
      return;
    }
    final clientId = json.remove('@client_id') as int?;
    if (clientId == null) return;
    _clients[clientId]?._handle(json);
  }

  static void _receiveLoop(SendPort sendPort) {
    final native = TdNative.load();
    while (true) {
      final result = native.receive(10.0);
      if (result != null) sendPort.send(result);
    }
  }

  @visibleForTesting
  void stop() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _port?.close();
    _port = null;
  }
}

/// One TDLib instance (one Telegram account).
class TdClient {
  TdClient._(this.id);

  final int id;
  final _updates = StreamController<td.TdObject>.broadcast(sync: true);
  final Map<int, Completer<td.TdObject>> _pending = {};
  final Map<int, String> _pendingNames = {};
  int _nextExtra = 0;
  bool _closed = false;

  /// Creates a TDLib client and starts receiving its updates.
  static Future<TdClient> create() async {
    final native = TdNative.load();
    await TdReceiver.instance._ensureStarted();
    final client = TdClient._(native.createClientId());
    TdReceiver.instance._register(client);
    // A client starts working only after it receives its first request.
    client._sendRaw({'@type': 'getOption', 'name': 'version'});
    return client;
  }

  /// Synchronous TDLib requests that do not need a client (log settings, text parsing).
  static Map<String, dynamic>? executeStatic(td.TdFunction function) {
    final result = TdNative.load().execute(jsonEncode(function.toJson()));
    return result == null ? null : jsonDecode(result) as Map<String, dynamic>;
  }

  Stream<td.TdObject> get updates => _updates.stream;

  Future<T> send<T extends td.TdObject>(td.TdFunction function) {
    if (_closed) return Future.error(StateError('TDLib client $id is closed'));
    final extra = ++_nextExtra;
    final completer = Completer<td.TdObject>();
    _pending[extra] = completer;
    _pendingNames[extra] = function.getConstructor();
    final json = function.toJson()..['@extra'] = extra;
    _sendRaw(json);
    return completer.future.then((result) {
      if (result is T) return result;
      throw StateError('TDLib returned ${result.getConstructor()} for ${function.getConstructor()}, expected $T');
    });
  }

  void _sendRaw(Map<String, dynamic> json) => TdNative.load().send(id, jsonEncode(json));

  void _handle(Map<String, dynamic> json) {
    final extra = json.remove('@extra');
    td.TdObject? object;
    try {
      object = json.toTdObject();
    } on Object catch (error) {
      debugPrint('tdlib: cannot decode ${json['@type']}: $error');
    }
    if (extra is int) {
      final completer = _pending.remove(extra);
      final name = _pendingNames.remove(extra) ?? '?';
      if (completer == null) return;
      if (object is td.TdError) {
        completer.completeError(TdException(object.code, object.message, name));
      } else if (object == null) {
        completer.completeError(TdException(500, 'UNDECODABLE_RESPONSE ${json['@type']}', name));
      } else {
        completer.complete(object);
      }
      return;
    }
    if (object != null && !_updates.isClosed) _updates.add(object);
    if (object is td.UpdateAuthorizationState && object.authorizationState is td.AuthorizationStateClosed) {
      _dispose();
    }
  }

  void _dispose() {
    if (_closed) return;
    _closed = true;
    TdReceiver.instance._unregister(this);
    for (final completer in _pending.values) {
      completer.completeError(TdException(500, 'CLIENT_CLOSED', 'pending'));
    }
    _pending.clear();
    _updates.close();
  }

  bool get isClosed => _closed;
}
