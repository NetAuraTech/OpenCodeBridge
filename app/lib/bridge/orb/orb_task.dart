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
    this.deliveryOwed = false,
    this.fallbackSent = false,
    this.textHash,
    this.dispatchId,
    this.toolchain,
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

  /// The orb image's toolchain (issue #354, acceptance #1): the pinned
  /// toolchains the sandbox image installs, stamped on the task at dispatch
  /// so the spawn answer carries them — a driver deciding whether a ticket
  /// can run in an orb reads them off the answer, no probe orb. The list is
  /// produced from the image definition (the Dockerfile ARGs,
  /// `OrbEmbedded.toolchain`), never hand-maintained here: a pin that moves
  /// in the image definition moves this list with it. `null` on a record
  /// written before the stamp existed.
  final List<String>? toolchain;

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

  /// The persisted **"delivery owed / done"** fact (issue #212, #260,
  /// acceptance #1): whether a settled task's completion is still owed to its
  /// caller in-app. `true` only for a settled task that has a caller and whose
  /// in-app injection has not yet landed (the caller was unreachable when it
  /// settled — the bridge retries the injection on the next chance it is
  /// reachable, and the push went out once as the out-of-band fallback);
  /// `false` while running, once the injection has landed, or for a task with
  /// no caller (nothing to deliver). The settle path's delivery policy writes
  /// this from its resulting state, and a restored plan reads it — a
  /// restarted bridge resumes the retry from here and never re-sends the
  /// fallback.
  bool deliveryOwed;

  /// The persisted **"fallback sent"** fact (issue #212, #260, acceptance #1):
  /// whether the once-sent push fallback has already fired. `true` means the
  /// push went out and must **never** go out again — even after a restart.
  /// This is the push-exactly-once guarantee made into an explicit, readable
  /// fact on the record, not a side effect of the retry step happening not to
  /// call the push (issue #260).
  bool fallbackSent;

  /// Whether the completion has been delivered in-app (the old "notified"
  /// reading): a settled task's [deliveryOwed] is `false`. Derived — it is not
  /// persisted; the persisted truth is the explicit [deliveryOwed] /
  /// [fallbackSent] facts above.
  bool get notified => !deliveryOwed;

  /// Adopts the delivery policy's resulting state (issue #260): writes this
  /// record's explicit delivery facts from the state the plan reports. The
  /// record is the truth — the settle path persists these after each delivery
  /// step, and a restarted bridge restores the plan from them.
  void applyDeliveryState({required bool owed, required bool fallbackSent}) {
    deliveryOwed = owed;
    this.fallbackSent = fallbackSent;
  }

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
    // Only-when-present (issue #354): a record written before the stamp
    // exists carries no toolchain, and the reader sees `null` for it.
    if (toolchain != null) 'toolchain': toolchain,
    'status': status,
    'summary': summary,
    'results': results,
    if (pr != null) 'pr': pr,
    if (completed != null) 'completed': completed,
    // Always written (issue #212, #260): the delivery's explicit facts. A
    // settled task that still owes its completion injection must reload as
    // still-owed, so the retry resumes — only-when-true would be
    // indistinguishable from a delivered one. And the fallback-sent fact is
    // what makes "push exactly once" survive a restart (a settled, still-owed
    // task whose push already went out must not be re-pushed).
    'deliveryOwed': deliveryOwed,
    'fallbackSent': fallbackSent,
  };

  factory OrbTask.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final caller = map['caller'] as String?;
    final hasCaller = caller != null && caller.isNotEmpty;
    final settled = map['completed'] != null;
    return OrbTask(
      id: map['id'] as String? ?? '',
      orb: map['orb'] as String? ?? '',
      project: map['project'] as String? ?? '',
      orbName: map['orbName'] as String? ?? '',
      branch: map['branch'] as String? ?? '',
      session: map['session'] as String? ?? '',
      callerSession: caller,
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
      // The image's toolchain (issue #354), stamped at dispatch: read back
      // on reload, `null` on a record that predates the stamp.
      toolchain: (map['toolchain'] as List<Object?>?)?.cast<String>(),
      // The explicit delivery facts (issue #260); a new record carries them.
      // A record written before they existed carries only the old `notified`
      // fact (issue #212) — or neither (a pre-#212 one): a settled
      // not-yet-notified one already pushed once at its settle, so it reads
      // back still-owed (the retry re-injects) and fallback-sent (never
      // re-pushed); a notified one (and a pre-#212 settled one, already
      // delivered or dropped) reads not-owed. A running one reads not-owed
      // (harmless: it settles through the new path).
      deliveryOwed:
          map['deliveryOwed'] as bool? ??
          (settled && !((map['notified'] as bool?) ?? settled) && hasCaller),
      fallbackSent:
          map['fallbackSent'] as bool? ??
          (settled && !((map['notified'] as bool?) ?? settled) && hasCaller),
    );
  }
}
