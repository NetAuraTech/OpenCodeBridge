import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/terminal/terminal_models.dart';

void main() {
  group('TerminalSize', () {
    test('defaultSize is the v1 120x30 worst case', () {
      expect(TerminalSize.defaultSize, const TerminalSize(cols: 120, rows: 30));
    });

    test('fromJson reads cols/rows and falls back to the default', () {
      expect(TerminalSize.fromJson({'cols': 80, 'rows': 24}).toJson(), {
        'cols': 80,
        'rows': 24,
      });
      // Missing/absent keys fall back to the default.
      expect(TerminalSize.fromJson(const {}), TerminalSize.defaultSize);
      expect(
        TerminalSize.fromJson({'cols': 100}).rows,
        TerminalSize.defaultSize.rows,
      );
    });
  });

  group('TerminalStatus', () {
    test('round-trips the service wire values', () {
      expect(TerminalStatus.fromWire('running'), TerminalStatus.running);
      expect(TerminalStatus.fromWire('exited'), TerminalStatus.exited);
      // Unknown is treated as exited (not running).
      expect(TerminalStatus.fromWire('weird'), TerminalStatus.exited);
    });
  });

  group('TerminalInfo', () {
    test('fromJson parses the service PersistentPty.Info subset', () {
      final info = TerminalInfo.fromJson({
        'id': 'pty_persistent_1',
        'title': 'OpenCode',
        'command': 'opencode',
        'args': ['--session', 'ses_1'],
        'cwd': '/proj',
        'status': 'running',
        'pid': 4242,
        'sessionID': 'ses_1',
        'foregroundProcess': 'opencode',
        'size': {'cols': 120, 'rows': 30},
      });
      expect(info.id, 'pty_persistent_1');
      expect(info.status, TerminalStatus.running);
      expect(info.sessionId, 'ses_1');
      expect(info.cwd, '/proj');
      expect(info.command, 'opencode');
      expect(info.args, ['--session', 'ses_1']);
      expect(info.size, TerminalSize.defaultSize);
    });

    test('fromJson is tolerant of missing fields', () {
      final info = TerminalInfo.fromJson({'id': 'pty_x'});
      expect(info.id, 'pty_x');
      expect(info.status, TerminalStatus.exited);
      expect(info.size, TerminalSize.defaultSize);
    });
  });

  group('TerminalTicket', () {
    test('fromJson reads the ticket and expiry', () {
      final ticket = TerminalTicket.fromJson({
        'ticket': 'abc',
        'expires_in': 60,
      });
      expect(ticket.ticket, 'abc');
      expect(ticket.expiresIn, 60);
    });
  });
}
