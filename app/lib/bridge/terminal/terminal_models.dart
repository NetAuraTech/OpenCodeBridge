/// The terminal slice's wire models (spec §7). These mirror the shared
/// opencode service's `PersistentPty` family: the bridge owns the PTYs it
/// creates for app-launched sessions and never re-implements a PTY
/// (ADR-0001).
library;

/// A PTY size in character cells.
class TerminalSize {
  const TerminalSize({required this.cols, required this.rows});

  /// The v1 default. Worst case for a session before the real window size is
  /// known (spec §16: "Worst case: fixed 120×30 in v1").
  static const TerminalSize defaultSize = TerminalSize(cols: 120, rows: 30);

  /// Columns (horizontal cells).
  final int cols;

  /// Rows (vertical cells).
  final int rows;

  Map<String, Object?> toJson() => {'cols': cols, 'rows': rows};

  factory TerminalSize.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return TerminalSize(
      cols: (map['cols'] as num?)?.toInt() ?? TerminalSize.defaultSize.cols,
      rows: (map['rows'] as num?)?.toInt() ?? TerminalSize.defaultSize.rows,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalSize && other.cols == cols && other.rows == rows;

  @override
  int get hashCode => Object.hash(cols, rows);

  @override
  String toString() => 'TerminalSize(${cols}x$rows)';
}

/// The lifecycle of one persistent PTY, as the service reports it.
enum TerminalStatus {
  /// The PTY's foreground process is running.
  running('running'),

  /// The PTY's foreground process has exited.
  exited('exited');

  const TerminalStatus(this.wire);

  /// The wire value on the service's `PersistentPty.Info.status`.
  final String wire;

  /// Tolerant wire parse: anything unknown is [TerminalStatus.exited].
  static TerminalStatus fromWire(Object? value) => switch (value) {
    'running' => TerminalStatus.running,
    _ => TerminalStatus.exited,
  };
}

/// One session-bound persistent PTY (the service's `PersistentPty.Info`),
/// narrowed to the fields the bridge acts on (spec §7).
class TerminalInfo {
  const TerminalInfo({
    required this.id,
    required this.status,
    required this.size,
    this.title = '',
    this.command = '',
    this.args = const [],
    this.cwd = '',
    this.pid = 0,
    this.sessionId = '',
    this.foregroundProcess,
  });

  final String id;

  /// The service's PTY title (the TUI sets it).
  final String title;

  /// The spawned command (`opencode`).
  final String command;

  /// The spawned arguments (`["--session", "<id>"]`).
  final List<String> args;

  /// The working directory the PTY was created in.
  final String cwd;

  final TerminalStatus status;

  /// The PTY's foreground process id (0 when unknown).
  final int pid;

  /// The session this PTY is bound to.
  final String sessionId;

  /// The service's `foregroundProcess` (e.g. `opencode`).
  final String? foregroundProcess;

  final TerminalSize size;

  factory TerminalInfo.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final args = map['args'];
    return TerminalInfo(
      id: map['id'] as String? ?? '',
      title: map['title'] as String? ?? '',
      command: map['command'] as String? ?? '',
      args: args is List ? args.map((a) => '$a').toList() : const <String>[],
      cwd: map['cwd'] as String? ?? '',
      status: TerminalStatus.fromWire(map['status']),
      pid: (map['pid'] as num?)?.toInt() ?? 0,
      sessionId: map['sessionID'] as String? ?? '',
      foregroundProcess: map['foregroundProcess'] as String?,
      size: TerminalSize.fromJson(map['size']),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'command': command,
    'args': args,
    'cwd': cwd,
    'status': status.wire,
    'pid': pid,
    'sessionID': sessionId,
    'foregroundProcess': foregroundProcess,
    'size': size.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is TerminalInfo && other.id == id && other.status == status;

  @override
  int get hashCode => Object.hash(id, status);

  @override
  String toString() => 'TerminalInfo(id: $id, status: ${status.wire})';
}

/// A short-lived ticket authorizing one `connect` of a PTY (the service's
/// `PtyTicket.ConnectToken`). Expires after [expiresIn] seconds.
class TerminalTicket {
  const TerminalTicket({required this.ticket, required this.expiresIn});

  /// The opaque ticket, passed as the `connect?ticket=` query parameter.
  final String ticket;

  /// Lifetime in seconds (the service issues 60).
  final int expiresIn;

  factory TerminalTicket.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return TerminalTicket(
      ticket: map['ticket'] as String? ?? '',
      expiresIn: (map['expires_in'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, Object?> toJson() => {'ticket': ticket, 'expires_in': expiresIn};
}
