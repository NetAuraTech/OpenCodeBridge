/// The opencode event types the app's consumers match off the unified
/// `GET /api/events` stream (spec §8) — the opencode half of the stream.
///
/// The stream carries two halves in one `data:` envelope: the opencode events
/// (re-emitted verbatim, durable seq included) and the bridge's own native
/// events ([`BridgeEventType`]). This class is the named home for the opencode
/// half, so both halves read the same way — a type matched against a constant
/// instead of a bare string literal. The values are the wire `type` strings
/// opencode emits; they are re-declared here, not imported, because the app
/// consumes them off its own client-decoded [BridgeEvent] and must not depend
/// on opencode's wire format by import.
///
/// [BridgeEventType] is the same idea for the bridge-native half (`session.
/// closed`, `docker.*`, …); the two classes are one vocabulary for one stream
/// (issue #254).
abstract class OpencodeEventType {
  /// The opencode event the agent's `question` tool raises: the form appears
  /// for the session to answer (issue #50). Its payload nests the session
  /// under `data.form`.
  static const String formCreated = 'form.created';

  /// The session answered the form.
  static const String formReplied = 'form.replied';

  /// The session dismissed the form without answering.
  static const String formCancelled = 'form.cancelled';

  /// The agent asked the user for permission to act (issue #24): the
  /// permission banner lights up. Carries no durable seq, so its session
  /// arrives as `data.sessionID`.
  static const String permissionAsked = 'permission.asked';

  /// The session answered the permission request (or it was resolved): the
  /// banner clears.
  static const String permissionReplied = 'permission.replied';

  /// A session was created (this service or a just-spawned orb): the home
  /// list must re-fetch to learn the row's location, project, and orb.
  static const String sessionCreated = 'session.created';

  /// A session's title changed: the row patches its title in place (no
  /// refetch).
  static const String sessionRenamed = 'session.renamed';

  /// A session was deleted (service-side): the row drops.
  static const String sessionDeleted = 'session.deleted';

  /// A session was archived (issue #235): the row flips to the Archived
  /// surface, in place.
  static const String sessionArchived = 'session.archived';

  /// A session was unarchived (issue #235): the row flips back to Active.
  static const String sessionUnarchived = 'session.unarchived';

  /// A turn began: the session is running again (the active dot, the live
  /// footer, and any stale cancel marker clear).
  static const String sessionExecutionStarted = 'session.execution.started';

  /// The turn ended having succeeded: the session goes idle.
  static const String sessionExecutionSucceeded = 'session.execution.succeeded';

  /// The turn ended in failure: the session goes idle.
  static const String sessionExecutionFailed = 'session.execution.failed';

  /// The turn ended interrupted (the user stopped it, or the service settled a
  /// cancelled turn as its terminal): the session goes idle.
  static const String sessionExecutionInterrupted =
      'session.execution.interrupted';

  /// The turn's cost/usage moved: the structured view's cost bar updates from
  /// the payload.
  static const String sessionUsageUpdated = 'session.usage.updated';

  /// A model step began: the structured view opens the step.
  static const String sessionStepStarted = 'session.step.started';

  /// A step streamed a chunk: the in-flight step grows in place.
  static const String sessionStepStreamed = 'session.step.streamed';

  /// A model step ended: the structured view records the context the model
  /// call used.
  static const String sessionStepEnded = 'session.step.ended';

  /// The context was compacted, streaming: the compaction marker grows in
  /// place.
  static const String sessionCompactionDelta = 'session.compaction.delta';

  /// The context compaction finished: the structured view settles the marker.
  static const String sessionCompactionEnded = 'session.compaction.ended';

  /// The assistant began emitting visible text: the message opens.
  static const String sessionTextStarted = 'session.text.started';

  /// The assistant streamed a text token: the in-flight message grows.
  static const String sessionTextDelta = 'session.text.delta';

  /// The assistant began reasoning: the reasoning part opens.
  static const String sessionReasoningStarted = 'session.reasoning.started';

  /// The assistant streamed a reasoning token: the in-flight reasoning grows.
  static const String sessionReasoningDelta = 'session.reasoning.delta';

  /// The assistant began filling a tool's input: the tool card opens.
  static const String sessionToolInputStarted = 'session.tool.input.started';

  /// The assistant finished filling a tool's input: the card records it.
  static const String sessionToolInputEnded = 'session.tool.input.ended';

  /// A tool was called: the card flips to running.
  static const String sessionToolCalled = 'session.tool.called';

  /// A tool finished successfully: the card records the result.
  static const String sessionToolSuccess = 'session.tool.success';

  /// A tool failed: the card records the failure.
  static const String sessionToolFailed = 'session.tool.failed';
}
