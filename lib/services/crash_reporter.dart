import 'crash_reporter_stub.dart'
    if (dart.library.io) 'crash_reporter_io.dart' as impl;

void reportCrash(String kind, Object error, StackTrace stack) {
  impl.reportCrash(kind, error, stack);
}
