import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('com.kinflow.kinflow/crash_log');

const String _downloadLogPath =
    '/storage/emulated/0/Download/kinflow_crash.log';
const String _oldLogPath =
    '/storage/emulated/0/Android/data/com.kinflow.kinflow/files/kinflow_crash.log';

void reportCrash(String kind, Object error, StackTrace stack) {
  final content = '[$kind] ${DateTime.now()}\n$error\n$stack\n\n';
  _writeViaChannel(content);
  _writeFallback(content);
}

Future<void> _writeViaChannel(String content) async {
  try {
    await _channel.invokeMethod<void>('writeDownloadLog', {
      'fileName': 'kinflow_crash.log',
      'content': content,
      'append': true,
    });
  } catch (_) {}
}

void _writeFallback(String content) {
  try {
    final file = File(_downloadLogPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content, mode: FileMode.append);
  } catch (_) {
    try {
      final file = File(_oldLogPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content, mode: FileMode.append);
    } catch (_) {}
  }
}
