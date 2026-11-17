// The events-side wire decode for the structured view's live path (issue
// #285). The model owns each shape (the history side decodes to the same
// values), and this module is the one place the events side decodes its
// payloads: each shape routes through the model's decoder, so a renamed or
// added wire field is a one-place change and the live path and the history
// path agree on the same fact.
//
// The view adapts, not decodes: it reads the values these functions return
// and applies them to its in-flight row/state.

import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/session_detail.dart';

/// The session's cumulative tokens from a `session.usage.updated` event's
/// `data` (the live cost bar): the `tokens` payload decoded through the
/// model's one events-side token decode ([TokenUsage.fromEventTokens], the
/// nested `cache.read` / `cache.write` flattened to the contract's
/// `cacheRead` / `cacheWrite`). `null` when the payload carries no `tokens`
/// (the cost bar then keeps its current usage).
TokenUsage? eventTokens(Object? data) {
  final map = data is Map<String, Object?> ? data : null;
  final tokens = map?['tokens'];
  return tokens == null ? null : TokenUsage.fromEventTokens(tokens);
}

/// The turn-stats facts a live step event records on the in-flight step (the
/// `session.step.ended` payload): the step's billed output/reasoning tokens,
/// and the context its model call used.
///
/// - [outputTokens] / [reasoningTokens] read the payload's `tokens.output` /
///   `tokens.reasoning` directly; a field the payload does not carry is `null`
///   (the step keeps its previous value).
/// - [contextTokens] is the call's total input — its `tokens.input` plus the
///   prompt-cache reads and writes — decoded through the model's one context
///   owner ([TokenUsage.contextTokensFrom], the same fact the history path
///   carries as `SessionMessage.contextTokens`), so the live path computes
///   the context the same way the history path does. `null` when the payload
///   carries no `tokens.input` (the arithmetic only applies to a call with an
///   input).
({int? outputTokens, int? reasoningTokens, int? contextTokens}) stepFacts(
  Object? data,
) {
  final map = data is Map<String, Object?> ? data : null;
  final tokens = map?['tokens'];
  if (tokens is! Map<String, Object?>) {
    return (outputTokens: null, reasoningTokens: null, contextTokens: null);
  }
  return (
    outputTokens: (tokens['output'] as num?)?.toInt(),
    reasoningTokens: (tokens['reasoning'] as num?)?.toInt(),
    contextTokens: TokenUsage.contextTokensFrom(tokens),
  );
}

/// The tool-state facts from a `session.tool.success` event's `data` (the
/// tool state the event carries): the file patch and the answers the user
/// gave the agent's `question` tool. Decoded by the model's one tool-state
/// decoder ([ToolCall.fromToolState]) — the same decode the history path
/// composes through — so the live card settles on the same patch/answers the
/// reopened history shows, and a renamed wire field is a one-place change.
({String? patch, List<List<String>>? answers}) toolStateFacts(Object? data) =>
    ToolCall.fromToolState(data);
