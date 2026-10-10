import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateClientIdNative = Int32 Function();
typedef _CreateClientId = int Function();
typedef _SendNative = Void Function(Int32 clientId, Pointer<Utf8> request);
typedef _Send = void Function(int clientId, Pointer<Utf8> request);
typedef _ReceiveNative = Pointer<Utf8> Function(Double timeout);
typedef _Receive = Pointer<Utf8> Function(double timeout);
typedef _ExecuteNative = Pointer<Utf8> Function(Pointer<Utf8> request);
typedef _Execute = Pointer<Utf8> Function(Pointer<Utf8> request);

/// Bindings to TDLib's JSON interface (td_json_client.h, `td_*` functions).
///
/// `td_receive` is shared by all clients of the process and must be called from a single thread,
/// so it runs in a dedicated isolate (see [TdReceiver]); `td_send`/`td_execute` are thread-safe.
class TdNative {
  TdNative._(DynamicLibrary library)
      : createClientId = library.lookupFunction<_CreateClientIdNative, _CreateClientId>('td_create_client_id'),
        _send = library.lookupFunction<_SendNative, _Send>('td_send'),
        _receive = library.lookupFunction<_ReceiveNative, _Receive>('td_receive'),
        _execute = library.lookupFunction<_ExecuteNative, _Execute>('td_execute');

  static TdNative? _instance;

  /// Loads libtdjson. `TDJSON_PATH` overrides the location (used by desktop tests).
  static TdNative load() => _instance ??= TdNative._(_open());

  static DynamicLibrary _open() {
    final override = Platform.environment['TDJSON_PATH'];
    if (override != null && override.isNotEmpty) return DynamicLibrary.open(override);
    if (Platform.isAndroid || Platform.isLinux) return DynamicLibrary.open('libtdjson.so');
    if (Platform.isIOS || Platform.isMacOS) {
      try {
        return DynamicLibrary.open('tdjson.framework/tdjson');
      } on ArgumentError {
        // Statically linked into the app binary.
        return DynamicLibrary.process();
      }
    }
    if (Platform.isWindows) return DynamicLibrary.open('tdjson.dll');
    throw UnsupportedError('TDLib is not available on ${Platform.operatingSystem}');
  }

  final int Function() createClientId;
  final _Send _send;
  final _Receive _receive;
  final _Execute _execute;

  void send(int clientId, String request) {
    final pointer = request.toNativeUtf8();
    try {
      _send(clientId, pointer);
    } finally {
      malloc.free(pointer);
    }
  }

  /// Returns the next response or update, or null on timeout. The returned memory is owned by TDLib.
  String? receive(double timeoutSeconds) {
    final result = _receive(timeoutSeconds);
    return result == nullptr ? null : result.toDartString();
  }

  String? execute(String request) {
    final pointer = request.toNativeUtf8();
    try {
      final result = _execute(pointer);
      return result == nullptr ? null : result.toDartString();
    } finally {
      malloc.free(pointer);
    }
  }
}
