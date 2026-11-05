import 'dart:convert';
import 'dart:io';

import 'package:opencodebridge/client/authenticated_http.dart';
import 'package:opencodebridge/model/command.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/project.dart';
import 'package:opencodebridge/model/question.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/model/session_detail.dart';

/// The app-side client of the bridge's sessions endpoints (spec section 5).
/// The app talks only to the bridge (ADR-0001): in server mode that is
/// loopback, in client mode the same API behind the tunnel (issue #23:
/// every request carries `Authorization: Bearer` from [auth], refreshed
/// on `401` — see [bridgeRequest]).
class SessionsClient {
  SessionsClient(this._base, {this._auth});

  /// The bridge's base URI, e.g. `http://127.0.0.1:48201/`.
  final Uri _base;

  /// The Access login's header provider (issue #23); `null` in server mode.
  final AuthHeaderProvider? _auth;

  /// Every session on the shared service, newest first (spec section 5,
  /// endpoint 1).
  Future<List<Session>> list() async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/sessions'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) Session.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The project list (spec section 5, fill-in †): the new-session project
  /// picker's rows, id + display name + canonical directory.
  Future<List<Project>> projects() async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/projects'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) Project.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Create a session in [projectId]'s project (spec section 5, fill-in †,
  /// endpoint 2). The body is only the project id; the bridge creates the
  /// session on the shared service, records the launch, and returns the
  /// session.
  Future<Session> create(String projectId) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/sessions'),
        body: jsonEncode({'project': projectId}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.created) {
        throw SessionsClientError(response.statusCode, body);
      }
      return Session.fromJson(jsonDecode(body));
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Create a session whose working directory is [directory] as-is (issue
  /// #54's "New project"): the body is the directory; the bridge checks it
  /// exists on this host and creates the session on the shared service, which
  /// auto-creates a project for a directory it has never seen.
  Future<Session> createInDirectory(String directory) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/sessions'),
        body: jsonEncode({'directory': directory}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.created) {
        throw SessionsClientError(response.statusCode, body);
      }
      return Session.fromJson(jsonDecode(body));
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Deletes a session (spec section 5, endpoint 4): the bridge performs the
  /// service deletion and the persistence-record removal in one action.
  Future<void> delete(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'DELETE',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}'),
        auth: _auth,
      );
      await response.drain<void>();
      if (response.statusCode != HttpStatus.noContent &&
          response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(
          response.statusCode,
          'delete of $id was not accepted',
        );
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The session's detail — state plus costs and token usage (spec
  /// section 5, endpoint 5).
  Future<SessionDetail> getDetail(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      return SessionDetail.fromJson(jsonDecode(body));
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The session's history as structured-view messages, the tools in
  /// flight included (spec section 5, endpoint 6).
  Future<List<SessionMessage>> getMessages(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/messages'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) SessionMessage.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Send a prompt (spec section 5, endpoint 7). The prompt is enabled at
  /// any time: the bridge forwards it to the service with `delivery:
  /// steer`, which queues a mid-turn prompt. [files] and [skills] are the
  /// optional attachment arrays (the TUI's `@` file/skill mentions) the
  /// service resolves at prompt time; a plain call sends exactly the text,
  /// as before.
  Future<void> prompt(
    String id,
    String text, {
    List<Map<String, Object?>>? files,
    List<Map<String, Object?>>? skills,
  }) async {
    final requestBody = <String, Object?>{'text': text};
    if (files != null && files.isNotEmpty) requestBody['files'] = files;
    if (skills != null && skills.isNotEmpty) requestBody['skills'] = skills;
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/messages'),
        body: jsonEncode(requestBody),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.accepted) {
        throw SessionsClientError(response.statusCode, body);
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The session's pending permission requests (spec section 5, endpoint
  /// 8).
  Future<List<PermissionRequest>> getPermissions(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(
          path: 'api/sessions/${Uri.encodeComponent(id)}/permissions',
        ),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) PermissionRequest.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Reply to a pending permission request (spec section 5, endpoint 9).
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(
          path:
              'api/sessions/${Uri.encodeComponent(id)}/permissions/'
              '${Uri.encodeComponent(requestID)}/reply',
        ),
        body: jsonEncode({'reply': reply.wire}),
        contentType: ContentType.json,
        auth: _auth,
      );
      await response.drain<void>();
      if (response.statusCode != HttpStatus.noContent &&
          response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(
          response.statusCode,
          'reply to $requestID was not accepted',
        );
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  // The structured view's question forms (issue #50): the agent's `question`
  // tool, answered or dismissed from the structured view. The bridge hides the
  // service's internal `q0`/`q1` field keys; the app answers per question, in
  // the form's field order.

  /// The session's pending question forms (issue #50).
  Future<List<QuestionForm>> getQuestions(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(
          path: 'api/sessions/${Uri.encodeComponent(id)}/questions',
        ),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) QuestionForm.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Submit the answers to a pending question form [formID] (issue #50).
  /// [answers] has one entry per question, in the form's field order.
  Future<void> answerQuestion(
    String id,
    String formID,
    List<List<String>> answers,
  ) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(
          path:
              'api/sessions/${Uri.encodeComponent(id)}/questions/'
              '${Uri.encodeComponent(formID)}/answer',
        ),
        body: jsonEncode({'answers': answers}),
        contentType: ContentType.json,
        auth: _auth,
      );
      await response.drain<void>();
      if (response.statusCode != HttpStatus.noContent &&
          response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(
          response.statusCode,
          'answer to $formID was not accepted',
        );
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Dismiss a pending question form [formID] (issue #50): the agent continues
  /// without an answer.
  Future<void> dismissQuestion(String id, String formID) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'DELETE',
        _base.replace(
          path:
              'api/sessions/${Uri.encodeComponent(id)}/questions/'
              '${Uri.encodeComponent(formID)}',
        ),
        auth: _auth,
      );
      await response.drain<void>();
      if (response.statusCode != HttpStatus.noContent &&
          response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(
          response.statusCode,
          'dismiss of $formID was not accepted',
        );
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  // The structured view's `/` command menu (issue #46). The per-session
  // commands run against the open session; the service is the single source
  // of truth, so their effect is reflected live in any attached TUI.

  /// The project's custom commands (the `/` menu's custom commands): the
  /// service's `GET /api/command` through the bridge.
  Future<List<OpencodeCommand>> listCommands(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/commands'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) OpencodeCommand.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Run one of the project's custom commands (the `/` menu's custom
  /// commands): the service's `POST /api/session/{id}/command`, run with
  /// `delivery: steer` so it queues mid-turn like a prompt. [text] is the
  /// text typed after the command name.
  Future<void> runCommand(String id, String name, String text) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(
          path:
              'api/sessions/${Uri.encodeComponent(id)}/commands/'
              '${Uri.encodeComponent(name)}',
        ),
        body: jsonEncode({'text': text}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.accepted) {
        throw SessionsClientError(response.statusCode, body);
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The model registry (the `/` menu's `/models` picker): the service's
  /// `GET /api/model` through the bridge.
  Future<List<ModelOption>> listModels(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/models'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) ModelOption.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The session's current model (the `/` menu's `/variants` picker: the
  /// variants of the model the session is on), or `null` when the service
  /// reports none yet.
  Future<ModelRef?> currentModel(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/model'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) {
        throw SessionsClientError(0, 'model returned no payload');
      }
      final model = decoded['model'];
      return model is Map<String, Object?> ? ModelRef.fromJson(model) : null;
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Set the session's model (the `/` menu's `/models` pick): the service's
  /// `POST /api/session/{id}/model`.
  Future<void> setModel(String id, ModelRef model) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/models'),
        body: jsonEncode({'model': model.toJson()}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.noContent) {
        throw SessionsClientError(response.statusCode, body);
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The agent registry (the `/` menu's `/agents` picker): the service's
  /// `GET /api/agent` through the bridge.
  Future<List<AgentOption>> listAgents(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/agents'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) AgentOption.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Set the session's agent (the `/` menu's `/agents` pick): the service's
  /// `POST /api/session/{id}/agent`.
  Future<void> setAgent(String id, String agentId) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/agents'),
        body: jsonEncode({'agent': agentId}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.noContent) {
        throw SessionsClientError(response.statusCode, body);
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The skill registry (the `/` menu's `/skills`): the service's
  /// `GET /api/skill` through the bridge.
  Future<List<SkillOption>> listSkills(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/skills'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) SkillOption.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The session's files for the `@` mention menu's file rows (issue #58):
  /// the service's `GET /api/fs/find` through the bridge, re-queried per
  /// typed token (the TUI re-queries on every keystroke). Returns the
  /// matched file paths relative to the session's working directory.
  Future<List<String>> findFiles(String id, String query) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(
          path: 'api/sessions/${Uri.encodeComponent(id)}/files',
          queryParameters: {'query': query},
        ),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [
        for (final item in list)
          if (item is String) item,
      ];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Activate a skill in the session (the `/` menu's `/skills` pick): the
  /// service's `POST /api/experimental/session/{id}/skill`.
  Future<void> activateSkill(String id, String skillId) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(
          path:
              'api/sessions/${Uri.encodeComponent(id)}/skills/'
              '${Uri.encodeComponent(skillId)}',
        ),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.noContent) {
        throw SessionsClientError(response.statusCode, body);
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Compact the session's context (the `/` menu's `/compact`).
  Future<void> compact(String id) => _postNoContent(id, 'compact');

  /// Undo the previous message (the `/` menu's `/undo`).
  Future<void> undo(String id) => _postNoContent(id, 'undo');

  /// Redo (the `/` menu's `/redo`).
  Future<void> redo(String id) => _postNoContent(id, 'redo');

  /// Rename the session (the `/` menu's `/rename <title>`).
  Future<void> rename(String id, String title) async {
    await _postField(id, 'rename', 'title', title);
  }

  /// Change the session's working directory (the `/` menu's
  /// `/cd <path>`).
  Future<void> move(String id, String directory) async {
    await _postField(id, 'move', 'directory', directory);
  }

  /// Move the session onto the orb [orbName] (issue #97): one action,
  /// entirely through the bridge — the target orb is woken (or created)
  /// before the session's export/import/delete. The bridge blocks for the
  /// whole move (a boot included) and answers 204; the session id is
  /// preserved, so a re-run over an already-moved session is the
  /// 409-idempotent success. A failure surfaces as a [SessionsClientError]
  /// whose message carries the wire `details` (the named refusal, the
  /// failed boot's log tail, the failed move's detail) or its error code.
  Future<void> moveToOrb(String id, String orbName) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(
          path: 'api/sessions/${Uri.encodeComponent(id)}/move-to-orb',
        ),
        body: jsonEncode({'orb': orbName}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.noContent) {
        throw SessionsClientError(response.statusCode, _moveDetail(body));
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The user-facing text of a move wire error body: its `details` field,
  /// its `error` code when there are none, or the raw body.
  static String _moveDetail(String body) {
    final decoded = const JsonDecoder().convert(body);
    final map = decoded is Map<String, Object?> ? decoded : const {};
    final details = map['details'] is String ? map['details'] as String : null;
    if (details != null) return details;
    final code = map['error'] is String ? map['error'] as String : null;
    return code ?? body;
  }

  /// The session's transcript (the `/` menu's `/export`): the service's
  /// `GET /api/experimental/session/{id}/export`, as its decoded JSON.
  Future<String> exportSession(String id) => _payload(id, 'export');

  /// The session's file diffs (the `/` menu's `/diff`): the service's
  /// `GET /api/session/{id}/diff`, as its decoded JSON.
  Future<String> diff(String id) => _payload(id, 'diff');

  /// The session's usage statistics (the `/` menu's `/stats`): the
  /// service's `GET /api/experimental/session/stats`, as its decoded JSON.
  Future<String> stats(String id) => _payload(id, 'stats');

  /// Fork the session (the `/` menu's `/fork`), returning the new session's
  /// id.
  Future<String> fork(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/fork'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?> && decoded['id'] is String) {
        return decoded['id'] as String;
      }
      throw SessionsClientError(HttpStatus.ok, 'fork returned no session id');
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Ask a one-shot side question (the `/` menu's `/btw <question>`): the
  /// service's `POST /api/session/{id}/generate`, not added to the
  /// conversation. Returns the generated text.
  Future<String> btw(String id, String prompt) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/btw'),
        body: jsonEncode({'prompt': prompt}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?> && decoded['text'] is String) {
        return decoded['text'] as String;
      }
      throw SessionsClientError(HttpStatus.ok, 'btw returned no text');
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  // The `/` menu's global commands (not tied to the open session).

  /// The account's usage limits (the `/` menu's `/usage`): the service's
  /// `GET /api/experimental/usage/limits`, as its decoded JSON.
  Future<String> usage() => _globalPayload('api/usage');

  /// The MCP servers (the `/` menu's `/mcps`): the service's
  /// `GET /api/mcp`, as its decoded JSON.
  Future<String> mcps() => _globalPayload('api/mcp');

  /// The plugins (the `/` menu's `/plugins`): the service's
  /// `GET /api/plugin`, as its decoded JSON.
  Future<String> plugins() => _globalPayload('api/plugins');

  /// The integrations (the `/` menu's `/connect` picker): the service's
  /// `GET /api/integration`, as its decoded JSON.
  Future<String> integrations() => _globalPayload('api/integrations');

  /// Start an integration's OAuth flow (the `/` menu's `/connect` pick): the
  /// service's `POST /api/integration/{id}/connect/oauth`, as its decoded
  /// JSON (the flow's URL, when the service hands one out).
  Future<String> connectIntegration(
    String integrationId,
    String methodId,
  ) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(
          path:
              'api/integrations/${Uri.encodeComponent(integrationId)}/connect',
        ),
        body: jsonEncode({'methodID': methodId}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      if (decoded is! String) {
        throw SessionsClientError(0, 'connect returned no payload');
      }
      return decoded;
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The service's info (the `/` menu's `/status`): the service's
  /// `GET /api/info`, as its decoded JSON.
  Future<String> status() => _globalPayload('api/status');

  /// Pair a device (the `/` menu's `/pair`): the service's
  /// `POST /api/pair`, as its decoded JSON.
  Future<String> pair() async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/pair'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      if (decoded is! String) {
        throw SessionsClientError(0, 'pair returned no payload');
      }
      return decoded;
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Reload the service's configuration (the `/` menu's `/reload`).
  Future<void> reload() async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/reload'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.noContent) {
        throw SessionsClientError(response.statusCode, body);
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The open session's project's worktrees (the `/` menu's
  /// `/worktrees`): the service's `GET /api/worktree?projectID=…` (the
  /// project resolved from [sessionId] on the service), as its decoded JSON.
  Future<String> worktrees(String sessionId) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(
          path: 'api/worktrees',
          queryParameters: {'sessionID': sessionId},
        ),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      if (decoded is! String) {
        throw SessionsClientError(0, 'worktrees returned no payload');
      }
      return decoded;
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// A body-less `POST` to the session's [sub] command endpoint expecting a
  /// 204 (the `/` menu's no-argument session commands).
  Future<void> _postNoContent(String id, String sub) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/$sub'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.noContent) {
        throw SessionsClientError(response.statusCode, body);
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// A `POST` to the session's [sub] command endpoint carrying [field] as
  /// [value], expecting a 204 (the `/` menu's argument session commands).
  Future<void> _postField(
    String id,
    String sub,
    String field,
    String value,
  ) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/$sub'),
        body: jsonEncode({field: value}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.noContent) {
        throw SessionsClientError(response.statusCode, body);
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// A `GET` of the session's [sub] payload endpoint, returning the
  /// service's decoded JSON as a string (the `/` menu's session "info"
  /// commands).
  Future<String> _payload(String id, String sub) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/$sub'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      if (decoded is! String) {
        throw SessionsClientError(0, '$sub returned no payload');
      }
      return decoded;
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// A `GET` of the bridge's global [path] payload endpoint, returning the
  /// service's decoded JSON as a string (the `/` menu's global "info"
  /// commands).
  Future<String> _globalPayload(String path) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: path),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      if (decoded is! String) {
        throw SessionsClientError(0, 'payload returned no string');
      }
      return decoded;
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }
}

/// A failure of a bridge sessions endpoint, carrying the bridge's status
/// (0 when the bridge could not be reached at all).
class SessionsClientError implements Exception {
  const SessionsClientError(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'SessionsClientError($statusCode: $message)';
}
