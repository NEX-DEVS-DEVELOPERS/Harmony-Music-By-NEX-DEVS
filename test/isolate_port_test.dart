import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonymusic/services/background_task.dart';

void main() {
  test('closure that captures a ReceivePort cannot go to an isolate (the bug)',
      () async {
    final receive = ReceivePort();
    final send = receive.sendPort;
    // captures `receive` too, exactly like the old checkNGetUrl code did
    final future = Isolate.run(() {
      send.send('hi');
      return receive.hashCode;
    });
    await expectLater(future, throwsA(isA<ArgumentError>()));
    receive.close();
  });

  test('runStreamLookup works with a status port (the fix)', () async {
    final receive = ReceivePort();
    final messages = <dynamic>[];
    receive.listen(messages.add);
    // token null -> ensureInitialized throws inside, which getStreamInfo turns
    // into an "unplayable" result instead of crashing: no network needed.
    final result =
        await runStreamLookup('abcdefghijk', null, receive.sendPort);
    expect(result['playable'], isFalse);
    expect(result['statusMSG'], isA<String>());
    receive.close();
  });
}
