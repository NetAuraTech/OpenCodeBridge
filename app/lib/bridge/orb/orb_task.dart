// The spawn surface's task record (issue #99, spec §8.2/§8.3): one `orb_spawn`
// dispatches a task onto an orb's opencode session; the record is what
// `orb_wait` returns and what the completion injection reports. It is the
// bridge's only durable state for the spawn surface — the file at
// `~/.config/opencodebridge/tasks.json` is what survives a bridge restart
// ("the result is persisted", spec §8.3).

/// One dispatched orb task.
class OrbTask {
  OrbTask({
    required this.id,
    required this.orb,
    required this.project,
    required this.orbName,
    required this.branch,
    required this.session,
    required this.task,
    required this.created,
    this.callerSession,
    this.callerDirectory,
    this.callerOrb,
    this.createdOrb = false,
    this.status = 'running',
    this.summary = '',
    this.pr,
    this.completed,
    this.textHash,
    this.dispatchId,
  });

  /// The task's technical id (`task_<token>`): what `orb_wait` takes.
  final String id;

  /// The orb id the task runs on.
  final String orb;

  /// The host project id the orb belongs to (issue #143): a retried dispatch
  /// and the recent-tasks read both resolve a project, and the dedup is
  /// per project's orb.
  final String project;

  /// The orb's user-facing name (the injection message addresses it).
  final String orbName;

  /// The orb's dedicated branch (`orb/<id>`): where the work lands.
  final String branch;

  /// The orb session the task was dispatched to.
  final String session;

  /// The calling session id (the injection target), or `null` when the
  /// caller could not be identified as a session.
  final String? callerSession;

  /// The calling session's working directory as the tool reported it (the
  /// caller-lookup fallback), or `null`.
  final String? callerDirectory;

  /// The orb the calling session ran inside at dispatch (issue #100, spec
  /// §8.4's spawn-tree edge: a nested spawn's tree runs through the
  /// caller's orb, recorded here because a later session move changes the
  /// live row). `null` for a host-session caller.
  final String? callerOrb;

  /// Whether this spawn **created** the task's orb (issue #100, spec §8.4):
  /// the task record doubles as the spawn-tree edge — the orb named
  /// [orb] belongs to [callerSession]'s spawn tree from this task on.
  final bool createdOrb;

  /// The free-text task handed to the orb's agent (exactly the caller's text,
  /// issue #147).
  final String task;

  /// The dispatch identity of [task] (issue #147): a SHA-256 of the raw caller
  /// text, persisted instead of a normalized copy so the idempotent dispatch
  /// can match a retry without comparing instructions lossily.
  final String? textHash;

  /// The caller's own id for this dispatch (issue #147), when it sent one: a
  /// retry repeats it, and a new id is always a new task. `null` when the
  /// caller sent none — the identity is then the raw text + the caller.
  final String? dispatchId;

  /// Epoch millis of the dispatch.
  final int created;

  /// `running` until the orb session's turn ends, then the service's
  /// outcome: `succeeded`, `failed`, or `interrupted`.
  String status;

  /// The orb agent's final message (its summary of the work), captured at
  /// completion; empty when unavailable.
  String summary;

  /// The branch's PR URL once one exists (the return channel, spec §3.2),
  /// or `null` when the work has none yet.
  String? pr;

  /// Epoch millis of the completion, or `null` while running.
  int? completed;

  /// Whether the task has reached its terminal status.
  bool get isDone => completed != null;

  /// The structured result's artifacts (spec §8.3's `results`): the branch
  /// always, the PR once it exists.
  List<String> get results => ['branch: $branch', if (pr != null) 'PR: $pr'];

  Map<String, Object?> toJson() => {
    'id': id,
    'orb': orb,
    'project': project,
    'orbName': orbName,
    'branch': branch,
    'session': session,
    if (callerSession != null) 'caller': callerSession,
    if (callerDirectory != null) 'callerDirectory': callerDirectory,
    if (callerOrb != null) 'callerOrb': callerOrb,
    if (createdOrb) 'createdOrb': true,
    'task': task,
    if (textHash != null) 'textHash': textHash,
    if (dispatchId != null) 'dispatchId': dispatchId,
    'created': created,
    'status': status,
    'summary': summary,
    'results': results,
    if (pr != null) 'pr': pr,
    if (completed != null) 'completed': completed,
  };

  factory OrbTask.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return OrbTask(
      id: map['id'] as String? ?? '',
      orb: map['orb'] as String? ?? '',
      project: map['project'] as String? ?? '',
      orbName: map['orbName'] as String? ?? '',
      branch: map['branch'] as String? ?? '',
      session: map['session'] as String? ?? '',
      callerSession: map['caller'] as String?,
      callerDirectory: map['callerDirectory'] as String?,
      callerOrb: map['callerOrb'] as String?,
      createdOrb: map['createdOrb'] == true,
      task: map['task'] as String? ?? '',
      textHash: map['textHash'] as String?,
      dispatchId: map['dispatchId'] as String?,
      created: (map['created'] as num?)?.toInt() ?? 0,
      status: map['status'] as String? ?? 'running',
      summary: map['summary'] as String? ?? '',
      pr: map['pr'] as String?,
      completed: (map['completed'] as num?)?.toInt(),
    );
  }
}
