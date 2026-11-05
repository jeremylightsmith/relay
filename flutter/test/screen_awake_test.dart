import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/voice/screen_awake.dart';

import 'support/fake_voice_transcriber.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> log;

  /// Scripts the native side of `relay/voice`. An Exception result is thrown.
  void mockNative(Object? Function(MethodCall call) answer) {
    log = [];
    messenger.setMockMethodCallHandler(IosScreenAwake.channel, (call) async {
      log.add(call);
      final value = answer(call);
      if (value is Exception) throw value;
      return value;
    });
  }

  tearDown(
    () => messenger.setMockMethodCallHandler(IosScreenAwake.channel, null),
  );

  test('setKeepAwake(true) sends on: true (scenario 1)', () async {
    mockNative((_) => null);

    await IosScreenAwake().setKeepAwake(true);

    expect(log.single.method, 'setKeepAwake');
    expect(log.single.arguments, {'on': true});
  });

  test('setKeepAwake(false) sends on: false (scenario 2)', () async {
    mockNative((_) => null);

    await IosScreenAwake().setKeepAwake(false);

    expect(log.single.method, 'setKeepAwake');
    expect(log.single.arguments, {'on': false});
  });

  test('a native PlatformException is swallowed — keep-awake never breaks '
      'dictation (scenario 3)', () async {
    mockNative(
      (call) => call.method == 'setKeepAwake'
          ? PlatformException(code: 'boom')
          : null,
    );

    await expectLater(IosScreenAwake().setKeepAwake(true), completes);
    expect(log, hasLength(1));
    expect(log.single.method, 'setKeepAwake');
  });

  test('a missing plugin is swallowed (scenario 4)', () async {
    mockNative(
      (call) => call.method == 'setKeepAwake'
          ? MissingPluginException('no voice plugin')
          : null,
    );

    await expectLater(IosScreenAwake().setKeepAwake(true), completes);
  });

  test('the fake records keep-awake calls made through engines '
      '(scenario 6)', () async {
    final fake = FakeVoiceTranscriber();

    await fake.engines.screenAwake.setKeepAwake(true);
    await fake.engines.screenAwake.setKeepAwake(false);

    expect(fake.keepAwakeCalls, [true, false]);
  });
}
