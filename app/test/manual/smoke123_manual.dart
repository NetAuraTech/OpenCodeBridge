// SMOKE (issue #123, manual — not part of the suite): the steer/queued turn
// stats against the REAL host opencode service, through the bridge's own
// message mapper (OpencodeHttpService.getMessages) and the real pure stats
// (computeTurnStats / liveTurnStats / turnWindow). Proves end to end:
//   1. a prompt STEERED mid-turn sits in the SAME turn window as the prompt
//      it steers (no idle marker between them, no second Turn boundary);
//   2. the live duration keeps anchoring at the FIRST prompt once the
//      steer is in the history (it does not restart at the steer);
//   3. a QUEUED prompt delivered after the closing idle opens the NEXT
//      window, where the frozen stats STILL describe the previous Turn
//      (the footer never vanishes), and that Turn's own frozen stats then
//      anchor at the queued prompt;
//   4. the footer is non-null on every snapshot once a completed step
//      exists.
// Run: flutter test test/manual/smoke123_manual.dart
// Creates and deletes ONLY its own throwaway session in /tmp/opencode.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/opencode_http_service.dart';
import 'package:opencodebridge/model/command.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/turn_stats.dart';

const _dir = '/tmp/opencode';
// A deliberately wordy first prompt: Turn 1 must run long enough for the
// steer to land mid-turn with certainty.
const _promptA =
    'Write a 3-sentence story about the sea. Finish with the line: '
    'smoke123-a';
const _promptB = 'Reply with exactly: smoke123-b';
const _promptC = 'Reply with exactly: smoke123-c';

void main() {
  test('smoke #123: steer + queue keep the turn stats correct, live', () async {
    final service = await OpencodeHttpService.fromHost();
    final session = await service.createSessionInDirectory(_dir);
    stderr.writeln('session ${session.id}');
    // The local free model keeps the run quick; a failure to select it only
    // slows the smoke down, it does not skew it.
    try {
      final models = await service.listModels();
      for (final wanted in ['flint']) {
        final pick = models.where((m) => m.id.contains(wanted));
        if (pick.isNotEmpty) {
          await service.setModel(
            session.id,
            ModelRef(id: pick.first.id, providerId: pick.first.providerId),
          );
          stderr.writeln('model ${pick.first.id}');
          break;
        }
      }
    } catch (e) {
      stderr.writeln('model pick skipped: $e (default model)');
    }

    final descriptor = jsonDecode(
      await File(
        '${Platform.environment['HOME']}/.local/state/opencode/service.json',
      ).readAsString(),
    ) as Map<String, Object?>;
    final base = Uri.parse(descriptor['url'] as String);
    final auth =
        'Basic '
        '${base64Encode(utf8.encode("opencode:${descriptor['password']}"))}';
    Future<void> send(String text, String delivery) async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          base.replace(
            path: '/api/session/${Uri.encodeComponent(session.id)}/prompt',
          ),
        );
        request.headers.set(HttpHeaders.authorizationHeader, auth);
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({'text': text, 'delivery': delivery}));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode >= 300) {
          throw StateError(
            '$delivery prompt failed: ${response.statusCode} $body',
          );
        }
        stderr.writeln('sent ($delivery): $text');
      } finally {
        client.close(force: true);
      }
    }

    int indexOfText(List<SessionMessage> messages, String text) =>
        messages.indexWhere((m) => m.role == 'user' && m.text == text);

    Future<List<SessionMessage>> until(
      bool Function(List<SessionMessage>) done,
      Duration budget,
      String what,
    ) async {
      final deadline = DateTime.now().add(budget);
      while (true) {
        final messages = await service.getMessages(session.id);
        if (done(messages)) return messages;
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('timeout waiting for $what');
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }

    // (4) The footer's non-null invariant: once a completed step exists,
    // no snapshot may drop the footer.
    var footerEverDropped = false;
    void check(List<SessionMessage> messages, String phase) {
      final hasStep = messages.any(
        (m) => m.role == 'assistant' && m.completed != null,
      );
      if (hasStep && computeTurnStats(messages) == null) {
        footerEverDropped = true;
        stderr.writeln('!! footer dropped during "$phase"');
      }
    }

    await send(_promptA, 'queue'); // Turn 1 starts.

    // (1) The turn is running before the steer goes in.
    await until(
      (m) => m.any((x) => x.role == 'assistant') && m.last.role != 'idle',
      const Duration(minutes: 2),
      'turn1 to start',
    );
    await send(_promptB, 'steer');

    // (1) The steer lands in the SAME window: no idle marker between A and B.
    final steered = await until(
      (m) =>
          indexOfText(m, _promptA) >= 0 &&
          indexOfText(m, _promptB) >= 0 &&
          m
              .sublist(indexOfText(m, _promptA), indexOfText(m, _promptB))
              .every((x) => x.role != 'idle'),
      const Duration(minutes: 3),
      'the steer to land',
    );
    stderr.writeln('steer in the same window (no idle between A and B)');

    // (2) With the steer in the history, the live window still anchors at A.
    final (liveStart, _) = turnWindow(steered);
    expect(
      liveStart,
      indexOfText(steered, _promptA),
      reason: 'the live window restarted at the steer',
    );
    final anchor = steered[liveStart].created;
    final now = DateTime.now().millisecondsSinceEpoch;
    final live = liveTurnStats(steered, now: now);
    expect(live, isNotNull);
    expect(
      (live!.duration!.inMilliseconds - (now - anchor!)).abs(),
      lessThan(2000),
      reason: 'the live duration no longer runs from the first prompt',
    );
    stderr.writeln('live duration anchored at A (${live.duration})');

    // Wait for Turn 1 (with its steered B) to CLOSE at an idle marker: the
    // frozen stats must describe A -> the last completed step, one footer.
    final closed = await until(
      (m) => m.last.role == 'idle',
      const Duration(minutes: 4),
      'turn1 to close',
    );
    final aIdx = indexOfText(closed, _promptA);
    final lastStep = closed
        .where((m) => m.role == 'assistant' && m.completed != null)
        .last;
    final frozen1 = computeTurnStats(closed);
    expect(frozen1?.duration, isNotNull);
    expect(
      frozen1!.duration!,
      Duration(milliseconds: lastStep.completed! - closed[aIdx].created!),
      reason: 'the frozen turn-1 footer did not span A -> last step',
    );
    stderr.writeln('turn 1 frozen footer: ${frozen1.label}');

    // Queue C AFTER the idle (the real queued-prompt case: the session is
    // idle, the inbox drains into a NEW turn). Then poll C's whole life:
    // (3a) if caught, the pending-C instant (window starts at C, no step)
    // must still show the frozen turn-1 footer — the footer never vanishes;
    // (3b/3c) C's own turn anchors its stats at C.
    await send(_promptC, 'queue');
    var sawPendingCFreeze = false;
    var sawTurn2AnchoredAtC = false;
    Duration? turn1FrozenDuration = frozen1.duration;
    Duration? turn2FrozenDuration;
    List<SessionMessage> last = closed;
    var ticks = 0;
    final deadline = DateTime.now().add(const Duration(minutes: 6));
    while (DateTime.now().isBefore(deadline)) {
      final messages = await service.getMessages(session.id);
      last = messages;
      check(messages, 'poll');
      if (++ticks % 80 == 0) {
        stderr.writeln(
          'poll: ${messages.length} messages, last=${messages.last.role}',
        );
      }
      final c = indexOfText(messages, _promptC);
      if (c >= 0) {
        final (start, end) = turnWindow(messages);
        final window = messages.sublist(start, end);
        final windowHasStep = window.any((m) => m.role == 'assistant');
        if (start == c && !windowHasStep) {
          // (3a) C is pending: the frozen stats must still describe turn 1.
          final stats = computeTurnStats(messages);
          if (stats != null) {
            sawPendingCFreeze = true;
            expect(
              stats.duration,
              turn1FrozenDuration,
              reason: 'the frozen footer did not survive the queued prompt',
            );
            stderr.writeln(
              'pending-C instant caught: footer stayed frozen '
              '(${stats.label})',
            );
          }
        } else if (start == c &&
            windowHasStep &&
            messages.last.role == 'idle') {
          // (3c) C's own turn CLOSED: the frozen window reads [c, idle] and
          // its stats anchor at C.
          sawTurn2AnchoredAtC = true;
          final stats = computeTurnStats(messages);
          turn2FrozenDuration = stats?.duration;
          final cCreated = messages[c].created;
          final lastCompleted = window
              .where((m) => m.role == 'assistant' && m.completed != null)
              .last
              .completed;
          expect(
            stats?.duration,
            Duration(milliseconds: lastCompleted! - cCreated!),
            reason: "turn 2's frozen stats did not anchor at C",
          );
          stderr.writeln(
            'turn 2 frozen stats anchored at C: '
            '${stats?.label}',
          );
          break;
        } else if (start == c && windowHasStep) {
          // (3b) C's own turn is running: its window anchors at C.
          sawTurn2AnchoredAtC = true;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    expect(footerEverDropped, isFalse, reason: 'a snapshot dropped the footer');
    // The pending-C instant between the idle and turn 2's start is a race
    // against the service (it drains the queue promptly); missing it is a
    // warning, the deterministic pin is the unit/widget test.
    if (!sawPendingCFreeze) {
      stderr.writeln(
        'WARN: never caught the pending-C instant (the service started '
        'turn 2 within the poll gap) — covered by the unit tests',
      );
    }
    expect(sawTurn2AnchoredAtC, isTrue, reason: 'turn 2 never anchored at C');
    stderr.writeln(
      'turn1 frozen ${turn1FrozenDuration?.inMilliseconds}ms; '
      'turn2 frozen ${turn2FrozenDuration?.inMilliseconds}ms',
    );
    stderr.writeln('final footer: ${computeTurnStats(last)?.label}');

    await service.deleteSession(session.id);
  }, timeout: const Timeout(Duration(minutes: 26)));
}
