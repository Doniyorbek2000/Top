import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../state/telegram.dart';

enum SaveResult { saved, denied, failed }

/// Saves a downloaded photo or video into the system gallery (album "Sado").
Future<SaveResult> saveToGallery(TelegramAccount account, td.File file, {required bool isVideo}) async {
  try {
    if (!await Gal.hasAccess(toAlbum: true) && !await Gal.requestAccess(toAlbum: true)) return SaveResult.denied;
    final path = file.local.isDownloadingCompleted ? file.local.path : await account.downloadFile(file.id, priority: 32);
    if (path == null || path.isEmpty) return SaveResult.failed;
    if (isVideo) {
      await Gal.putVideo(path, album: 'Sado');
    } else {
      await Gal.putImage(path, album: 'Sado');
    }
    return SaveResult.saved;
  } on GalException catch (error) {
    debugPrint('save to gallery failed: ${error.type}');
    return error.type == GalExceptionType.accessDenied ? SaveResult.denied : SaveResult.failed;
  }
}
