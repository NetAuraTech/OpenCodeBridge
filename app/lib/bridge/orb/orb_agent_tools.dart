import 'dart:io';

import '../sessions/paths.dart';

/// The spawn surface's global opencode agent tools (issue #99, spec §8.1):
/// the TypeScript file behind `orb_spawn` and `orb_wait`, embedded in the
/// binary and materialized, **create-if-missing**, into the global plugins
/// dir `~/.config/opencode/plugins/` at bridge startup — the same "app-owned
/// files, on-disk copy wins" pattern as the orb build context (§5.2).
///
/// opencode v2 loads agent tools through **plugins** (a file exporting
/// `{ id, setup }` whose `setup` registers tools through
/// `ctx.tool.transform`); the v1 `tools/` file convention it replaced is not
/// loaded by v2 servers (verified against opencode v2.1.4), so the surface is
/// one small dependency-free plugin, not per-tool `tool()` files.
///
/// Global placement is the point: nothing is committed to any repo, and
/// every orb's opencode inherits the plugin through the host config copied at
/// every start (§6.2) — which is what makes nested spawning work. The tools
/// call only the bridge's HTTP API (§8.1: never docker): from the host that
/// is `http://127.0.0.1:<bridge-port>`; from inside an orb the tools read the
/// `bridgeUrl` the bridge writes into the container-local config at every
/// copy (`http://host.docker.internal:<port>`, §6.2/§8.5).
abstract class OrbAgentTools {
  /// The plugin dir name inside the opencode config dir (opencode v2's
  /// auto-discovered global plugins location).
  static const String pluginDirName = 'plugins';

  /// The global plugins dir, `~/.config/opencode/plugins/` — inherited by
  /// every orb through the config copy.
  static Directory hostDir() =>
      Directory('${homeDirectory()}/.config/opencode/$pluginDirName');

  /// The plugin sources, keyed by file name.
  static const Map<String, String> files = {
    'opencodebridge_orbs.ts': _spawnPlugin,
  };

  /// Materialize the embedded plugin into [into] (the global plugins dir,
  /// [hostDir], by default), create-if-missing and never overwrite (an agent
  /// or the user may have tuned a copy; reset = delete the file, the next
  /// startup re-materializes it). Safe to call at every startup.
  static Future<void> materialize({Directory? into}) async {
    final dir = into ?? hostDir();
    await dir.create(recursive: true);
    for (final entry in files.entries) {
      final file = File('${dir.path}/${entry.key}');
      if (file.existsSync()) continue; // The on-disk copy wins.
      await file.writeAsString(entry.value);
    }
  }

  /// One plugin registering the spawn-surface tools (spec §8.2/§8.3/§8.4):
  /// `orb_spawn` wakes-or-creates the targeted orb and dispatches the task
  /// (project never an argument — the tool passes its session id and the
  /// bridge resolves the project from the session row), `orb_wait` blocks
  /// until a dispatched task completes and returns the structured result,
  /// and `orb_stop`/`orb_delete`/`orb_export` are the spawn-tree-scoped orb
  /// controls (issue #100 — the bridge scopes every call to the caller's
  /// tree; the human is unrestricted).
  static const String _spawnPlugin = r'''
import fs from "fs"
import os from "os"
import path from "path"

// Resolve the bridge's URL (spec §6.2/§8.5): the env override, then the
// `bridgeUrl` the bridge writes into the opencode config at every copy
// (present inside every orb, where localhost is not the host), then the
// host loopback default with the bridge's pinned port.
function bridgeUrl() {
  const override = process.env.OPENCODEBRIDGE_URL
  if (override) return override.replace(/\/+$/, "")
  for (const name of ["opencode.jsonc", "opencode.json"]) {
    try {
      const text = fs.readFileSync(path.join(os.homedir(), ".config", "opencode", name), "utf8")
      const match = text.match(/"bridgeUrl"\s*:\s*"([^"]+)"/)
      if (match) return match[1].replace(/\/+$/, "")
    } catch {}
  }
  return "http://127.0.0.1:48201"
}

function describe(row) {
  const lines = []
  lines.push(`Orb ${row.orbName} (${row.orb}) — task ${row.id}`)
  lines.push(`Status: ${row.status}`)
  lines.push(`Branch: ${row.branch}`)
  if (row.summary) lines.push("", row.summary)
  if (row.pr) lines.push("", `PR: ${row.pr}`)
  if (row.status === "refused") {
    // Issue #149: the orb exists but its agent cannot execute — nothing ran,
    // and the reason (the boot's own) is the answer.
    lines.push("", "Refused: this orb cannot run commands, so no work happened there.")
  } else if (row.status === "running") {
    lines.push("", `Still running — no need to poll: this session receives a message when the task completes. To check in the same turn, call orb_wait with task_id "${row.id}".`)
  }
  return lines.join("\n")
}

// The bridge's structured task row (spec §8.3), rendered for the agent.
const output = { type: "object", properties: { output: { type: "string" } }, required: ["output"] }

// The recent tasks of this session's project (issue #143), newest first: the
// bridge's /api/orb/tasks, asked by the directory the tool runs in. Read after
// a spawn whose transport failed, so the caller learns whether the dispatch
// landed instead of guessing "unreachable". No project -> no tasks. Only this
// session's own dispatches count (issue #147): another session's running task
// is never reported as this one's.
async function recentTasks(directory, session) {
  try {
    const response = await fetch(bridgeUrl() + "/api/orb/tasks", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ directory, session }),
    })
    if (!response.ok) return []
    const row = await response.json()
    const tasks = row && Array.isArray(row.tasks) ? row.tasks : []
    return tasks.slice(0, 5)
  } catch {
    return []
  }
}

// The task text as the bridge receives and dispatches it: the caller's words,
// followed by the bridge's return contract — commit (a post-commit hook pushes
// to the orb's branch), then open the PR (head = the orb's branch, base = the
// branch the clone started from) once the work is done, and end with the PR
// URL. A retry of this exact text is the same dispatch (issue #143/#147: the
// bridge dedups the raw text per calling session).
function fullySpecified(task) {
  return task + "\n\n" +
    "(Orb task: work in this workspace and commit your changes — a post-commit hook pushes them. " +
    "When the whole piece of work is done, open the PR with `gh pr create`. " +
    "One PR per orb, later tasks push to the same branch.)"
}

async function post(pathname, body) {
  const response = await fetch(bridgeUrl() + pathname, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  })
  const row = await response.json().catch(() => null)
  return { ok: response.ok, status: response.status, row }
}

export default {
  id: "opencodebridge.spawn",
  async setup(ctx) {
    ctx.tool.transform((editor) => {
      editor.add({
        name: "orb_spawn",
        description:
          "Dispatch a task to an orb (the Docker sandbox workspace): wakes the targeted or " +
          "project's single orb, creates one when none exists, or creates the additional orb " +
          "when the given name is not taken yet. Sends the task to its agent and returns the " +
          "task as soon as the dispatch lands — the work runs in the background, and this " +
          "session receives a message when it completes (do not poll; end your turn and the " +
          "completion will wake you). Pass wait: true to hold this call briefly for a quick " +
          "task (the hold is bounded; a still-running task answers as running). The work lands " +
          "on the orb's dedicated branch (orb/<id>) — the orb's agent commits and the branch is " +
          "pushed after every commit. The project is not an argument: this session's project " +
          "is used.",
        input: {
          type: "object",
          properties: {
            task: { type: "string", description: "Free text given to the orb's agent" },
            model: {
              type: "string",
              description: 'Model as "provider/model" (e.g. "zhipu/glm-4.7"); default = this session\'s model',
            },
            wait: {
              type: "boolean",
              description:
                "Hold the call briefly for a quick task (bounded); default false — the dispatch " +
                "answers immediately and the completion message wakes this session later. A " +
                "retried spawn of the very same task (the identical text from the same session, e.g. after " +
                "a timeout) returns the already-running task — it is not duplicated. A different task " +
                "text is always dispatched anew, even while another task runs on the orb.",
            },
            orb: {
              type: "string",
              description:
                "Name of the target orb: an existing orb's name wakes-or-uses it; an unused name creates " +
                "that additional orb (fresh clone, fresh branch). Omitted: the project's single orb — when " +
                "several exist the tool refuses and lists them, so retry with an explicit name.",
            },
            seed: {
              type: "string",
              description:
                "Name of an orb to clone from: the new orb's clone starts from the seed's pushed branch tip " +
                "(git state only, read from the remote — the seed may be stopped), and its PR stacks on the " +
                "seed's branch instead of the default branch. Only parameterizes a creation — pass it with a " +
                "new orb name.",
            },
          },
          required: ["task"],
        },
        output,
        async execute(args, context) {
          let model
          if (args.model) {
            const slash = args.model.indexOf("/")
            if (slash <= 0 || slash === args.model.length - 1) {
              return { output: 'Invalid model "' + args.model + '": expected "provider/model".' }
            }
            model = { providerID: args.model.slice(0, slash), id: args.model.slice(slash + 1) }
          }
          let result
          try {
            result = await post("/api/orb/spawn", {
              task: fullySpecified(args.task),
              model,
              wait: args.wait ?? false,
              orb: args.orb,
              seed: args.seed,
              session: context?.sessionID,
            })
          } catch (e) {
            // The fetch failed (issue #143): a blocking spawn holds the
            // response for the task, which commonly outlives the caller's
            // timeout while the bridge dispatches on. Ask for the project's
            // recent tasks before declaring the bridge unreachable: the
            // dispatch usually landed, and a blind error invites a duplicate
            // retry (the bridge dedups identical running tasks, but the
            // caller should not rely on it).
            const recent = await recentTasks(context?.directory, context?.sessionID)
            if (recent.length > 0) {
              return {
                output:
                  "Orb spawn: the call failed before an answer arrived (" +
                  e +
                  "), but the bridge took the dispatch. Its recent tasks:\n\n" +
                  recent.map((row) => `${row.id} — ${row.orbName} — ${row.status} — ${row.task}`).join("\n") +
                  "\n\nDo not call orb_spawn again for the same task. Use orb_wait with the matching task_id.",
              }
            }
            return { output: "Orb spawn failed: the OpenCodeBridge is unreachable at " + bridgeUrl() + " (" + e + ")." }
          }
          if (!result.ok) {
            const row = result.row
            const code = row && row.error ? row.error : "http_" + result.status
            if (code === "orb_ambiguous") {
              return {
                output:
                  "Several orbs exist in this project: " +
                  (row.orbs || []).join(", ") +
                  '. Retry orb_spawn with the "orb" argument set to one of these names.',
              }
            }
            if (code === "project_unknown") {
              return { output: "Orb spawn refused: this session's project is unknown to the bridge." }
            }
            if (code === "not_running") {
              return { output: "Orb spawn refused: the project's orb is broken. Fix or delete it from the app's Orbs tab." }
            }
            if (code === "no_shell") {
              // Issue #149: the orb exists, but its agent cannot run a
              // command — no commit, no push, no PR can come out of a task
              // dispatched onto it. Say so instead of dispatching.
              return {
                output:
                  "Orb spawn refused (no_shell): no task was dispatched — the orb's agent cannot run a shell " +
                  "command, so it cannot commit, push or open the PR. The boot reported: " +
                  (row.details || "no usable shell") +
                  " Nothing is running there. Do the work in this session instead, or fix the orb (delete and " +
                  "re-create it) from the app's Orbs tab.",
              }
            }
            if (code === "seed_not_found" || code === "seed_not_pushed" || code === "seed_conflict") {
              return { output: "Orb spawn refused (" + code + "): " + (row.details || "see the seed rules, spec §3.3.") }
            }
            return { output: "Orb spawn failed: " + code + (result.row && result.row.details ? " — " + result.row.details : "") }
          }
          return { output: describe(result.row) }
        },
      })
      editor.add({
        name: "orb_wait",
        description:
          "Ask once whether an orb task dispatched by orb_spawn has completed, holding " +
          "briefly for it (the hold is bounded): returns the structured result — status, " +
          "summary, the artifacts (branch, PR URL once the work has a PR) — or the task as " +
          "running. Prefer finishing your turn without waiting: the completion message wakes " +
          "this session by itself; call this only when you must answer in the same turn, and " +
          "a running answer means call it again later, not that the bridge is down.",
        input: {
          type: "object",
          properties: {
            task_id: { type: "string", description: 'The task id orb_spawn returned ("task_…")' },
          },
          required: ["task_id"],
        },
        output,
        async execute(args, context) {
          let result
          try {
            result = await post("/api/orb/wait", { id: args.task_id, session: context?.sessionID })
          } catch (e) {
            return { output: "Orb wait failed: the OpenCodeBridge is unreachable at " + bridgeUrl() + " (" + e + ")." }
          }
          if (!result.ok) {
            const row = result.row
            const code = row && row.error ? row.error : "http_" + result.status
            if (code === "not_found") {
              return { output: 'No orb task "' + args.task_id + '". The bridge persists its tasks — check the id orb_spawn returned.' }
            }
            if (code === "permission_denied") {
              return { output: "Orb wait refused: that task's orb is outside this session's spawn tree." }
            }
            return { output: "Orb wait failed: " + code }
          }
          return { output: describe(result.row) }
        },
      })
      // The spawn-tree controls (spec §8.4): stop / delete / export of the
      // orbs inside this session's spawn tree — never another agent's orb,
      // never the orb this session runs inside. The bridge scopes every
      // call; the human's own controls are the app's, not these tools.
      const orbRefInput = {
        type: "object",
        properties: {
          orb: { type: "string", description: "Name of the orb (or its id)" },
          force: { type: "boolean", description: "orb_delete only: override the deletion guard (discard the prototype without committing)" },
        },
        required: ["orb"],
      }
      const control = async (verb, doneWord, pathname, args, context) => {
        let result
        try {
          result = await post(pathname, { orb: args.orb, force: args.force === true, session: context?.sessionID })
        } catch (e) {
          return { output: "Orb " + verb + " failed: the OpenCodeBridge is unreachable at " + bridgeUrl() + " (" + e + ")." }
        }
        if (!result.ok) {
          const row = result.row
          const code = row && row.error ? row.error : "http_" + result.status
          if (code === "permission_denied") {
            return { output: "Refused: orb \"" + args.orb + "\" is outside this session's spawn tree (an agent controls only the orbs it spawned)." }
          }
          if (code === "deletion_refused") {
            return {
              output:
                "Orb delete refused — uncommitted or unpushed changes: " +
                (row.reasons || []).join("; ") +
                ". Commit and let the push finish, or pass force: true to discard the work deliberately.",
            }
          }
          if (code === "not_found") {
            return { output: 'No orb "' + args.orb + '" in this project.' }
          }
          return { output: "Orb " + verb + " failed: " + code + (result.row && result.row.details ? " — " + result.row.details : "") }
        }
        if (verb === "export") {
          const path = result.row && result.row.path
          return { output: "Orb " + args.orb + " exported." + (path ? " Archive: " + path : "") }
        }
        return { output: "Orb " + args.orb + " " + doneWord + "." }
      }
      editor.add({
        name: "orb_stop",
        description:
          "Stop an orb of this session's spawn tree (the sessions it holds move to the host). " +
          "Wake it again with orb_spawn targeting its name.",
        input: orbRefInput,
        output,
        async execute(args, context) {
          return control("stop", "stopped", "/api/orb/stop", args, context)
        },
      })
      editor.add({
        name: "orb_delete",
        description:
          "Delete an orb of this session's spawn tree (container, volumes, state). Refused while " +
          "changes are uncommitted or unpushed; force: true discards them deliberately (the losing " +
          "prototype variant — the intended force case).",
        input: orbRefInput,
        output,
        async execute(args, context) {
          return control("delete", "deleted", "/api/orb/delete", args, context)
        },
      })
      editor.add({
        name: "orb_export",
        description:
          "Export an orb of this session's spawn tree: a tar.gz of the whole workspace (uncommitted " +
          "state included) placed next to the project's checkout on the host.",
        input: orbRefInput,
        output,
        async execute(args, context) {
          return control("export", "exported", "/api/orb/export", args, context)
        },
      })
    })
  },
}
''';
}
