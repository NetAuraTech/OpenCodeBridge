import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/terminal/terminal_models.dart';
import 'package:opencodebridge/bridge/terminal/terminal_window.dart';
import 'package:opencodebridge/bridge/terminal/window_manager.dart';

void main() {
  late Directory dir;
  late Set<String> live;
  late List<String> events;
  late File app;
  late File emulator;
  var launches = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('opencodebridge-windows');
    live = <String>{};
    events = <String>[];
    launches = 0;
    // A "binary" (the attach client) that runs long until killed.
    app = File('${dir.path}/fake-app');
    app.writeAsStringSync('#!/bin/sh\nsleep 300\n');
    _chmod(app.path, '755');
    // An emulator that runs the attach client (its argv after `--`) as a
    // child and waits for it, like gnome-terminal --wait.
    emulator = File('${dir.path}/gnome-terminal');
    emulator.writeAsStringSync(
      '#!/bin/sh\n'
      'echo "\$@" > ${_argsFile(dir).path}\n'
      'while [ \$# -gt 0 ]; do\n'
      '  if [ "\$1" = "--" ]; then shift; break; fi\n'
      '  shift\n'
      'done\n'
      '"\$@" &\n'
      'echo \$! > ${dir.path}/pid.txt\n'
      'wait\n',
    );
    _chmod(emulator.path, '755');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  TerminalWindowSpawner makeSpawner() => TerminalWindowSpawner(
    emulators: (String name) => name == 'gnome-terminal' ? emulator.path : null,
    launch: (List<String> argv) {
      launches++;
      return Process.start(argv.first, argv.sublist(1));
    },
  );

  TerminalWindowManager makeManager({
    TerminalSize size = TerminalSize.defaultSize,
  }) => TerminalWindowManager(
    liveSessionIds: live,
    spawner: makeSpawner(),
    terminalBinary: app.path,
    windowToken: () => 'tok_1',
    onEvent: events.add,
    size: size,
  );

  test(
    'openFor spawns the attach client with the window token and flips live',
    () async {
      final manager = makeManager();
      try {
        await manager.openFor('ses_1');

        expect(launches, 1);
        expect(
          _argsFile(dir).readAsStringSync().trim(),
          '--wait --geometry 120x30 -- ${app.path} --attach-terminal '
          '--session ses_1 --token tok_1 --size 120x30',
        );
        expect(live, {'ses_1'});
        expect(manager.isLive('ses_1'), isTrue);
      } finally {
        await manager.close();
      }
    },
  );

  test('openFor opens one window per session', () async {
    final manager = makeManager();
    try {
      await manager.openFor('ses_1');
      await manager.openFor('ses_1');

      expect(launches, 1);
      expect(live, {'ses_1'});
    } finally {
      await manager.close();
    }
  });

  test('a window exit flips not-live and emits terminal.closed', () async {
    // A window that closes on its own (the user closed it).
    emulator.writeAsStringSync(
      '#!/bin/sh\n'
      'echo "\$@" > ${_argsFile(dir).path}\n'
      'exit 0\n',
    );
    final manager = makeManager();
    await manager.openFor('ses_1');

    await _until(() => live.isEmpty && events.isNotEmpty);

    expect(manager.isLive('ses_1'), isFalse);
    expect(events, hasLength(1));
    final frame = jsonDecode(events.single) as Map<String, Object?>;
    expect(frame['type'], 'terminal.closed');
    expect(frame['data'], {'sessionID': 'ses_1'});
    expect(frame.containsKey('durable'), isFalse);
  });

  test(
    'closeFor kills the window and flips not-live, without emitting',
    () async {
      final manager = makeManager();
      await manager.openFor('ses_1');
      await _waitForFile('${dir.path}/pid.txt');
      final pid = int.parse(
        File('${dir.path}/pid.txt').readAsStringSync().trim(),
      );
      expect(Process.runSync('kill', ['-0', '$pid']).exitCode, 0);

      await manager.closeFor('ses_1');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(Process.runSync('kill', ['-0', '$pid']).exitCode, isNot(0));
      expect(live, isEmpty);
      expect(manager.isLive('ses_1'), isFalse);
      expect(events, isEmpty);
    },
  );

  test('closeFor of a session without a window is a no-op', () async {
    final manager = makeManager();
    await manager.closeFor('ses_nope');
    expect(launches, 0);
    expect(live, isEmpty);
  });

  test('close kills every open window', () async {
    final manager = makeManager();
    await manager.openFor('ses_1');
    await manager.openFor('ses_2');
    await _waitForFile('${dir.path}/pid.txt');
    final pid1 = int.parse(
      File('${dir.path}/pid.txt').readAsStringSync().trim(),
    );

    await manager.close();

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(Process.runSync('kill', ['-0', '$pid1']).exitCode, isNot(0));
    expect(live, isEmpty);
    expect(events, isEmpty);
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The emulator script writes [path] once the attach client child is up;
/// [spawn] resolves before that, so poll for the file.
Future<void> _waitForFile(String path) async {
  await _until(() => File(path).existsSync());
}

File _argsFile(Directory dir) => File('${dir.path}/args.txt');

void _chmod(String path, String mode) => Process.runSync('chmod', [mode, path]);
