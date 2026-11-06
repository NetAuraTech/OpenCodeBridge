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

  /// One plugin registering both spawn-surface tools (spec §8.2/§8.3):
  /// `orb_spawn` wakes-or-creates the project's orb and dispatches the task
  /// (project never an argument — the tool passes its session id and the
  /// bridge resolves the project from the session row), `orb_wait` blocks
  /// until a dispatched task completes and returns the structured result.
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
  if (row.status === "running") {
    lines.push("", `To wait for this task later, call orb_wait with task_id "${row.id}".`)
  }
  return lines.join("\n")
}

// The bridge's structured task row (spec §8.3), rendered for the agent.
const output = { type: "object", properties: { output: { type: "string" } }, required: ["output"] }

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
          "Dispatch a task to the project's orb (the Docker sandbox workspace): wakes the " +
          "project's orb or creates one, sends the task to its agent, and by default waits " +
          "for the result. The work lands on the orb's dedicated branch (orb/<id>) — the " +
          "orb's agent commits and the branch is pushed after every commit. The project is " +
          "not an argument: this session's project is used.",
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
              description: "Block until the task completes (default true); false returns the orb handle immediately",
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
              task: args.task,
              model,
              wait: args.wait ?? true,
              session: context?.sessionID,
            })
          } catch (e) {
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
                  ". Targeting by orb name lands with the next bridge version; until then use " +
                  "the single-orb project or stop/delete the extra orbs.",
              }
            }
            if (code === "project_unknown") {
              return { output: "Orb spawn refused: this session's project is unknown to the bridge." }
            }
            if (code === "not_running") {
              return { output: "Orb spawn refused: the project's orb is broken. Fix or delete it from the app's Orbs tab." }
            }
            return { output: "Orb spawn failed: " + code + (result.row && result.row.details ? " — " + result.row.details : "") }
          }
          return { output: describe(result.row) }
        },
      })
      editor.add({
        name: "orb_wait",
        description:
          "Wait for an orb task dispatched by orb_spawn (wait: false) to complete, and " +
          "return its structured result: status, summary, the artifacts (branch, PR URL " +
          "once the work has a PR).",
        input: {
          type: "object",
          properties: {
            task_id: { type: "string", description: 'The task id orb_spawn returned ("task_…")' },
          },
          required: ["task_id"],
        },
        output,
        async execute(args) {
          let result
          try {
            result = await post("/api/orb/wait", { id: args.task_id })
          } catch (e) {
            return { output: "Orb wait failed: the OpenCodeBridge is unreachable at " + bridgeUrl() + " (" + e + ")." }
          }
          if (!result.ok) {
            const row = result.row
            const code = row && row.error ? row.error : "http_" + result.status
            if (code === "not_found") {
              return { output: 'No orb task "' + args.task_id + '". The bridge persists its tasks — check the id orb_spawn returned.' }
            }
            return { output: "Orb wait failed: " + code }
          }
          return { output: describe(result.row) }
        },
      })
    })
  },
}
''';
}
