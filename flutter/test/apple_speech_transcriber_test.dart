import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/voice/apple_speech_transcriber.dart';
import 'package:relay_mobile/features/voice/voice_transcriber.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> log;
  MockStreamHandlerEventSink? sink;

  /// Scripts the native side of `relay/voice`. An [overrides] result that is an
  /// Exception is thrown; any other non-null value is returned.
  void mockNative({FutureOr<Object?> Function(MethodCall call)? overrides}) {
    log = [];
    messenger.setMockMethodCallHandler(AppleSpeechTranscriber.channel, (
      call,
    ) async {
      log.add(call);
      final override = await overrides?.call(call);
      if (override is Exception) throw override;
      return override;
    });
  }

  /// Scripts the native side of `relay/voice/events`; [sink] is set once Dart
  /// subscribes.
  setUp(() {
    sink = null;
    mockNative();
    messenger.setMockStreamHandler(
      AppleSpeechTranscriber.events,
      MockStreamHandler.inline(onListen: (_, events) => sink = events),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(AppleSpeechTranscriber.channel, null);
    messenger.setMockStreamHandler(AppleSpeechTranscriber.events, null);
  });

  List<String> methods() => log.map((c) => c.method).toList();

  test('liveSupport maps every native name; an unknown one is unsupported '
      '(scenario 1)', () async {
    final answers = ['ready', 'needsDownload', 'unsupported', 'bogus'];
    mockNative(
      overrides: (call) =>
          call.method == 'liveSupport' ? answers.removeAt(0) : null,
    );
    final apple = AppleSpeechTranscriber();

    expect(await apple.liveSupport(), LiveSupport.ready);
    expect(await apple.liveSupport(), LiveSupport.needsDownload);
    expect(await apple.liveSupport(), LiveSupport.unsupported);
    expect(await apple.liveSupport(), LiveSupport.unsupported);
  });

  test('a null liveSupport answer is unsupported, never a throw', () async {
    expect(
      await AppleSpeechTranscriber().liveSupport(),
      LiveSupport.unsupported,
    );
  });

  test(
    'a liveSupport channel failure reads as unsupported, never a throw',
    () async {
      final failures = <Exception>[
        PlatformException(code: 'boom'),
        MissingPluginException(),
      ];
      mockNative(
        overrides: (call) =>
            call.method == 'liveSupport' ? failures.removeAt(0) : null,
      );
      final apple = AppleSpeechTranscriber();

      expect(await apple.liveSupport(), LiveSupport.unsupported);
      expect(await apple.liveSupport(), LiveSupport.unsupported);
    },
  );

  test('requestSpeechAuthorization is true for granted, false for denied '
      '(scenario 2)', () async {
    final answers = ['granted', 'denied'];
    mockNative(
      overrides: (call) =>
          call.method == 'requestSpeechPermission' ? answers.removeAt(0) : null,
    );
    final apple = AppleSpeechTranscriber();

    expect(await apple.requestSpeechAuthorization(), isTrue);
    expect(await apple.requestSpeechAuthorization(), isFalse);
  });

  test('live results stream draft then final words after startLive '
      '(scenario 3)', () async {
    final apple = AppleSpeechTranscriber();
    final got = <LiveResult>[];
    apple.results.listen(got.add);

    await apple.startLive();
    await pumpEventQueue();
    sink!.success({'type': 'result', 'text': 'ship it', 'isFinal': false});
    sink!.success({'type': 'result', 'text': 'Ship it.', 'isFinal': true});
    await pumpEventQueue();

    expect(got, const [
      LiveResult('ship it', isFinal: false),
      LiveResult('Ship it.', isFinal: true),
    ]);
    expect(methods(), ['startLive']);
  });

  test(
    'a startLive failure is VoiceError(recordingFailed) (scenario 4)',
    () async {
      mockNative(
        overrides: (call) => call.method == 'startLive'
            ? PlatformException(code: 'recording_failed')
            : null,
      );

      await expectLater(
        AppleSpeechTranscriber().startLive(),
        throwsA(
          isA<VoiceError>().having(
            (e) => e.kind,
            'kind',
            VoiceErrorKind.recordingFailed,
          ),
        ),
      );
    },
  );

  test('downloadAsset yields progress events then completes when native '
      'installs (scenario 5)', () async {
    final installed = Completer<Object?>();
    mockNative(
      overrides: (call) =>
          call.method == 'downloadAsset' ? installed.future : null,
    );
    final apple = AppleSpeechTranscriber();

    final collected = apple.downloadAsset().toList();
    await pumpEventQueue();
    sink!.success({'type': 'progress', 'fraction': 0.25});
    sink!.success({'type': 'progress', 'fraction': 0.62});
    await pumpEventQueue();
    installed.complete(null);

    expect(await collected, [0.25, 0.62]);
    expect(methods(), ['downloadAsset']);
  });

  test('progress sent in the same turn as the install reply is not dropped '
      '(scenario 5)', () async {
    mockNative(
      overrides: (call) {
        if (call.method == 'downloadAsset') {
          sink!.success({'type': 'progress', 'fraction': 0.25});
          sink!.success({'type': 'progress', 'fraction': 0.62});
        }
        return null;
      },
    );

    expect(await AppleSpeechTranscriber().downloadAsset().toList(), [
      0.25,
      0.62,
    ]);
  });

  test('a failed download errors the stream with '
      'VoiceError(assetDownloadFailed) (scenario 6)', () async {
    mockNative(
      overrides: (call) => call.method == 'downloadAsset'
          ? PlatformException(code: 'asset_download_failed')
          : null,
    );

    await expectLater(
      AppleSpeechTranscriber().downloadAsset(),
      emitsError(
        isA<VoiceError>().having(
          (e) => e.kind,
          'kind',
          VoiceErrorKind.assetDownloadFailed,
        ),
      ),
    );
  });

  test('a missing native plugin errors the download stream instead of '
      'escaping as an uncaught error', () async {
    mockNative(
      overrides: (call) =>
          call.method == 'downloadAsset' ? MissingPluginException() : null,
    );

    await expectLater(
      AppleSpeechTranscriber().downloadAsset(),
      emitsError(
        isA<VoiceError>().having(
          (e) => e.kind,
          'kind',
          VoiceErrorKind.assetDownloadFailed,
        ),
      ),
    );
  });

  test('an interrupted event fires the handler exactly once; an unknown '
      'event fires nothing (scenario 7)', () async {
    final apple = AppleSpeechTranscriber();
    final got = <LiveResult>[];
    apple.results.listen(got.add);
    var interruptions = 0;
    apple.onInterrupted(() => interruptions++);
    await pumpEventQueue();

    sink!.success({'type': 'interrupted'});
    await pumpEventQueue();
    expect(interruptions, 1);

    sink!.success({'type': 'mystery'});
    await pumpEventQueue();
    expect(interruptions, 1);
    expect(got, isEmpty);
  });

  test('stop and cancel call native and never delete a file '
      '(scenario 8)', () async {
    final apple = AppleSpeechTranscriber();

    await apple.stopLive();
    await apple.cancelLive();

    expect(methods(), ['stopLive', 'cancelLive']);
    expect(methods(), isNot(contains('deleteRecording')));
  });

  test('the constructor does not subscribe to events', () async {
    AppleSpeechTranscriber();
    await pumpEventQueue();

    expect(sink, isNull);
  });

  test('LiveResult has value equality and a readable toString', () {
    expect(
      const LiveResult('a', isFinal: true),
      const LiveResult('a', isFinal: true),
    );
    expect(
      const LiveResult('a', isFinal: true).hashCode,
      const LiveResult('a', isFinal: true).hashCode,
    );
    expect(
      const LiveResult('a', isFinal: true),
      isNot(const LiveResult('a', isFinal: false)),
    );
    expect(
      const LiveResult('a', isFinal: true).toString(),
      "LiveResult('a', isFinal: true)",
    );
  });
}
