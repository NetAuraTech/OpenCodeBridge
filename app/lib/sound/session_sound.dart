import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../bridge/events/bridge_event.dart';
import '../bridge/events/opencode_event_types.dart';
import '../bridge/sessions/cancel_dedup.dart';
import '../client/events_client.dart';

/// The sounds a session event can call for (issue #246): one per distinct
/// tone, so the event→sound mapping (and the error vs. success distinction)
/// is asserted against tones, not raw asset paths.
enum SessionSound {
  /// The turn finished cleanly (a bright single "ding", quick decay).
  success,

  /// The turn failed (a low, drawn-out "boop" — the only low tone, and
  /// the longest tail).
  error,

  /// The turn was interrupted, or stopped from a panel (a short, neutral,
  /// snappy mid note).
  stopped,

  /// A permission was requested or a question asked (a rich mid chime —
  /// attention without the success brightness).
  attention,
}

/// The bundled asset behind each [SessionSound] (a short, quiet, mono
/// 16-bit PCM WAV; the generator is `tools/gen_session_tones.py`). Kept on
/// the small, quiet side on purpose — the goal is a "ping", not an alarm.
extension SessionSoundAsset on SessionSound {
  String get assetPath => switch (this) {
    SessionSound.success => 'assets/sounds/session_success.wav',
    SessionSound.error => 'assets/sounds/session_error.wav',
    SessionSound.stopped => 'assets/sounds/session_stopped.wav',
    SessionSound.attention => 'assets/sounds/session_attention.wav',
  };
}

/// Maps an event off the unified `GET /api/events` stream onto the session
/// sound it deserves (issue #246), or `null` when the event plays nothing.
///
/// This is the single place that knows which events make a sound: the
/// trigger set, the distinct tone per outcome, and the cancelled-turn rule —
/// a turn stopped from a panel emits `session.turn.cancelled` **and** a
/// follow-on `session.execution.interrupted` for the same turn, and the
/// "stopped" sound must play once, not twice (the same suppression the push
/// dispatcher applies, issue #164).
///
/// Resolutions never play: a permission answered (`permission.replied`) or a
/// question resolved (`form.replied` / `form.cancelled`) is not an event the
/// user needs to hear about.
class SessionSoundMapper {
  /// The cancel's follow-on dedup (issues #164, #258): the service's own
  /// terminal for a cancelled turn (`session.execution.interrupted`) is not
  /// sounded again — the classifier says when it is the follow-on of a
  /// cancel already sounded as the stopped tone, not a genuine interrupt.
  final CancelDedup _dedup = CancelDedup();

  /// The [SessionSound] [event.type] calls for — `null` when the event plays
  /// nothing (a non-trigger, an event without a session, or the suppressed
  /// cancel follow-on terminal).
  SessionSound? soundFor(BridgeEvent event) {
    final sessionId = event.sessionId;
    switch (event.type) {
      case OpencodeEventType.sessionExecutionStarted:
        // A fresh turn: a stale cancel marker (its terminal missed, e.g.
        // across a service restart) must not suppress this turn's later
        // outcomes.
        if (sessionId != null) _dedup.started(sessionId);
        return null;
      case BridgeEventType.turnCancelled:
        if (sessionId == null) return null;
        _dedup.cancelled(sessionId);
        return SessionSound.stopped;
      case OpencodeEventType.sessionExecutionSucceeded:
        return _namesSession(sessionId) ? SessionSound.success : null;
      case OpencodeEventType.sessionExecutionFailed:
        return _namesSession(sessionId) ? SessionSound.error : null;
      case OpencodeEventType.sessionExecutionInterrupted:
        if (sessionId == null) return null;
        if (_dedup.isCancelledFollowOn(sessionId)) {
          // The cancel already sounded this turn's end as "stopped": its
          // service terminal is the same stop, not a new outcome.
          return null;
        }
        return SessionSound.stopped;
      case OpencodeEventType.permissionAsked:
      case OpencodeEventType.formCreated:
        return _namesSession(sessionId) ? SessionSound.attention : null;
      default:
        // Every other event on the stream (deltas, replies, resolutions,
        // bridge-native, ...): no sound.
        return null;
    }
  }

  /// The trigger events name their session (the durable seq, or
  /// `data.sessionID`); one without a session has nothing to sound for.
  bool _namesSession(String? sessionId) =>
      sessionId != null && sessionId.isNotEmpty;
}

/// Plays the desktop sounds on significant session events (issue #246).
///
/// Listens to the bridge's unified event stream — the same stream the
/// Sessions tab consumes, kept alive across tab switches by the shell's
/// `IndexedStack` — and plays the mapped tone for every trigger event while
/// the app is running and connected, regardless of the open tab or window
/// focus.
///
/// Desktop only: the platform gate ([defaultTargetPlatform] is not Android)
/// is read per event, so an Android device never plays any of these sounds —
/// FCM push (`lib/notify/notification_service.dart`) already covers those
/// moments there. The user's toggle ([AppSettings.soundEvents]) is read per
/// event too, so a live change from Settings takes effect immediately.
class SessionSoundService {
  SessionSoundService({
    required this.play,
    required this.asset,
    required this.platform,
    required this.enabled,
    SessionSoundMapper? mapper,
  }) : _mapper = mapper ?? SessionSoundMapper();

  /// The production wiring: [AudioBackend] for playback, [rootBundle] for
  /// the bundled assets, and [defaultTargetPlatform] for the gate. [enabled]
  /// is the persisted on/off toggle, read per event (the app hands it a
  /// closure over its live settings, so a change from Settings applies
  /// immediately). The event source is supplied later, by the shell, through
  /// [attach] (the Sessions tab's source; it may appear and disappear as the
  /// tunnel URL is set or cleared).
  factory SessionSoundService.live(bool Function() enabled) {
    return SessionSoundService(
      play: AudioBackend.play,
      asset: (path) async {
        final data = await rootBundle.load(path);
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      },
      platform: () => defaultTargetPlatform,
      enabled: enabled,
    );
  }

  /// Plays a raw mono 16-bit PCM WAV; the [AudioBackend] returns the
  /// process's exit code, and a throw is a failed play.
  final Future<int> Function(Uint8List wav) play;

  /// Loads a bundled sound asset; `null` (a missing asset) plays nothing.
  final Future<Uint8List?> Function(String assetPath) asset;

  /// The platform gate, read per event (tests override the platform with
  /// `debugDefaultTargetPlatformOverride`, which this reads).
  final TargetPlatform Function() platform;

  /// The persisted on/off toggle, read per event (live changes apply).
  final bool Function() enabled;

  final SessionSoundMapper _mapper;
  StreamSubscription<BridgeEvent>? _sub;

  /// (Re)points the service at [source]'s event stream (a fresh source per
  /// connection, and `null` — no bridge configured — for silence). Idempotent
  /// per source; the previous stream is unsubscribed.
  Future<void> attach(EventSource? source) async {
    final previous = _sub;
    _sub = null;
    if (previous != null) unawaited(previous.cancel());
    if (source == null) return;
    _sub = source.events.listen(_onEvent);
  }

  /// Stops listening (the app is going away).
  Future<void> detach() => attach(null);

  /// One event off the stream: play the mapped tone when the desktop gate
  /// and the settings toggle both allow it. Every failure (a missing asset,
  /// an unavailable sound device, ...) is swallowed — a throw here would
  /// tear down the subscription for every later event, and the sound is
  /// decorative.
  Future<void> _onEvent(BridgeEvent event) async {
    if (platform() == TargetPlatform.android) return;
    if (!enabled()) return;
    final sound = _mapper.soundFor(event);
    if (sound == null) return;
    try {
      final bytes = await asset(sound.assetPath);
      if (bytes == null || bytes.isEmpty) return; // A missing asset: silent.
      await play(bytes);
    } catch (_) {
      // Stay quiet: no sound beats a dead event stream.
    }
  }
}

/// The audio backend (the dependency-light path the issue prefers over an
/// audio plugin — no new package): hands a bundled mono 16-bit PCM WAV to the
/// desktop sound system through a short-lived child process ([Process.start]).
///
/// Linux pipes the WAV to whichever PulseAudio/PipeWire player is present
/// (`paplay`, then `pw-play`, then ALSA's `aplay`); Windows plays it through
/// PowerShell's `SoundPlayer`. The bytes are staged in a private file under
/// the system temp dir (deleted afterwards), so no app-owned file is touched.
/// [play] returns the player's exit code; any nonzero code — or a missing
/// player — is a failed play, which the caller swallows.
class AudioBackend {
  /// Plays [wav] through the host's audio. Fails (returns nonzero) when no
  /// player is available or the platform has no backend.
  static Future<int> play(Uint8List wav) {
    final os = Platform.operatingSystem;
    if (os == 'linux') return _playLinux(wav);
    if (os == 'windows') return _playWindows(wav);
    return Future<int>.error(UnsupportedError('no audio backend for $os'));
  }

  /// The Linux player resolved on the first play (the `PATH` probe runs once,
  /// not per event): `null` until then, or `''` when none was found.
  static String? _linuxPlayer;

  /// Tries the PulseAudio/PipeWire players in order until one succeeds. The
  /// first that is present on the `PATH` is cached and reused for the next
  /// plays (the probe is one fork we do not want to pay per event). Each
  /// player auto-detects the WAV from the file header, so the staged file is
  /// the only argument.
  static Future<int> _playLinux(Uint8List wav) async {
    final players = const ['paplay', 'pw-play', 'aplay'];
    final cached = _linuxPlayer;
    if (cached != null && cached.isEmpty) return 1; // Probed: none present.
    if (cached != null) {
      final staged = await _stage(wav);
      try {
        return await _runOnFile(cached, const <String>[], staged);
      } finally {
        staged.dispose();
      }
    }
    for (final player in players) {
      if (!await _canRun(player)) continue;
      _linuxPlayer = player;
      final staged = await _stage(wav);
      try {
        final code = await _runOnFile(player, const <String>[], staged);
        if (code == 0) return code;
      } catch (_) {
        // The player failed to start: try the next one.
      } finally {
        staged.dispose();
      }
    }
    _linuxPlayer = '';
    return 1;
  }

  /// PowerShell's `SoundPlayer` (a process-local play — no COM apartment
  /// needed). The staged WAV's path goes through an environment variable,
  /// keeping the command line free of path quoting. `PlaySync` blocks until
  /// the (short) tone finishes, so the process does not exit mid-sound.
  static Future<int> _playWindows(Uint8List wav) async {
    const script = r'''
Add-Type -AssemblyName System.Windows.Forms
try {
  $player = New-Object System.Windows.Forms.SoundPlayer([Environment]::GetEnvironmentVariable('OPENCODEBRIDGE_SOUND_WAV'))
  $player.PlaySync()
  exit 0
} catch {
  exit 1
}
''';
    final staged = await _stage(wav);
    try {
      return await _runOnFile(
        'powershell',
        const ['-NoProfile', '-NonInteractive', '-Command', script],
        staged,
        environment: {
          ...Platform.environment,
          'OPENCODEBRIDGE_SOUND_WAV': staged.path,
        },
      );
    } finally {
      staged.dispose();
    }
  }

  /// Runs [executable] with the staged WAV's path as its final argument and
  /// returns the child's exit code.
  static Future<int> _runOnFile(
    String executable,
    List<String> arguments,
    _StagedWav staged, {
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(executable, [
      ...arguments,
      staged.path,
    ], environment: environment);
    await process.stdin.close();
    return process.exitCode;
  }

  /// True when [executable] is on the `PATH`.
  static Future<bool> _canRun(String executable) async {
    try {
      final result = Platform.isWindows
          ? await Process.run('cmd', ['/c', 'where', executable])
          : await Process.run('which', [executable]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Writes [wav] to a private temp file; [StagedWav.dispose] removes it.
  static Future<_StagedWav> _stage(Uint8List wav) async {
    final dir = await Directory.systemTemp.createTemp('opencodebridge-sound-');
    final file = File('${dir.path}${Platform.pathSeparator}tone.wav');
    await file.writeAsBytes(wav);
    return _StagedWav(dir: dir, file: file);
  }
}

class _StagedWav {
  _StagedWav({required this.dir, required this.file});

  final Directory dir;
  final File file;

  String get path => file.path;

  void dispose() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // A leftover temp file is harmless (the OS reaps the temp dir).
    }
  }
}
