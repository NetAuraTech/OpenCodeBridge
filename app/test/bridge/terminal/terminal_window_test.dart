import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/terminal/terminal_models.dart';
import 'package:opencodebridge/bridge/terminal/terminal_window.dart';

void main() {
  group('buildTerminalWindowCommand', () {
    const client = ['app', '--attach-terminal'];

    test('prefers gnome-terminal --wait, passing the client after --', () {
      final command = buildTerminalWindowCommand(
        gnomeTerminal: '/usr/bin/gnome-terminal',
        xterm: '/usr/bin/xterm',
        attachClientArgv: client,
      );
      expect(command.argv, [
        '/usr/bin/gnome-terminal',
        '--wait',
        '--geometry',
        '120x30',
        '--',
        ...client,
      ]);
    });

    test('falls back to xterm -e', () {
      final command = buildTerminalWindowCommand(
        xterm: '/usr/bin/xterm',
        attachClientArgv: client,
      );
      expect(command.argv, [
        '/usr/bin/xterm',
        '-geometry',
        '120x30',
        '-e',
        ...client,
      ]);
    });

    test('honors a requested size', () {
      final command = buildTerminalWindowCommand(
        gnomeTerminal: '/usr/bin/gnome-terminal',
        xterm: null,
        attachClientArgv: client,
        size: const TerminalSize(cols: 132, rows: 43),
      );
      expect(command.argv, contains('132x43'));
    });

    test('throws when no emulator is available', () {
      expect(
        () => buildTerminalWindowCommand(attachClientArgv: client),
        throwsA(isA<TerminalEmulatorMissing>()),
      );
    });
  });

  group('TerminalWindowSpawner', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('opencodebridge-window');
    });

    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    test('spawns the preferred emulator hosting the attach client', () async {
      final script = _markerEmulator(dir);
      final window = await TerminalWindowSpawner(
        emulators: (String name) =>
            name == 'gnome-terminal' ? script.path : null,
      ).spawn(attachClientArgv: ['attach', '--session', 's']);
      expect(await window.exited, 0);
      expect(
        _argsFile(dir).readAsStringSync().trim(),
        '--wait --geometry 120x30 -- attach --session s',
      );
    });

    test('spawns the xterm fallback when gnome-terminal is absent', () async {
      final script = _markerEmulator(dir, 'fake-xterm');
      final window = await TerminalWindowSpawner(
        emulators: (String name) => name == 'xterm' ? script.path : null,
      ).spawn(attachClientArgv: ['attach', '--session', 's']);
      expect(await window.exited, 0);
      expect(
        _argsFile(dir).readAsStringSync().trim(),
        '-geometry 120x30 -e attach --session s',
      );
    });

    test('propagates the attach client exit code (window closed)', () async {
      final script = _markerEmulator(dir, 'exiting');
      script.writeAsStringSync(
        '#!/bin/sh\n'
        'echo "\$@" > ${_argsFile(dir).path}\n'
        'exit 3\n',
      );
      final window = await TerminalWindowSpawner(
        emulators: (String name) =>
            name == 'gnome-terminal' ? script.path : null,
      ).spawn(attachClientArgv: ['attach']);
      expect(await window.exited, 3);
    });

    test('throws when no emulator is available', () async {
      final spawner = TerminalWindowSpawner(emulators: (String name) => null);
      expect(
        () => spawner.spawn(attachClientArgv: ['attach']),
        throwsA(isA<TerminalEmulatorMissing>()),
      );
    });
  });

  group('findHostEmulator', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('opencodebridge-emulators');
    });

    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    test('finds an executable on PATH', () {
      final script = File('${dir.path}/gnome-terminal');
      script.writeAsStringSync('#!/bin/sh\n');
      _chmod(script.path, '755');
      expect(findHostEmulator('gnome-terminal', path: dir.path), script.path);
    });

    test('skips non-executable files and missing names', () {
      final plain = File('${dir.path}/gnome-terminal');
      plain.writeAsStringSync('not an executable');
      _chmod(plain.path, '644');
      expect(findHostEmulator('gnome-terminal', path: dir.path), isNull);
      expect(findHostEmulator('nope', path: dir.path), isNull);
    });
  });
}

/// A marker "emulator": a shell script that records its argv and exits.
File _markerEmulator(Directory dir, [String name = 'fake-gnome-terminal']) {
  final script = File('${dir.path}/$name');
  script.writeAsStringSync(
    '#!/bin/sh\n'
    'echo "\$@" > ${_argsFile(dir).path}\n',
  );
  _chmod(script.path, '755');
  return script;
}

File _argsFile(Directory dir) => File('${dir.path}/args.txt');

void _chmod(String path, String mode) => Process.runSync('chmod', [mode, path]);
