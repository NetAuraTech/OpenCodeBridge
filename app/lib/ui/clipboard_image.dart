// The clipboard-image read (issue #72) and its process-platform default
// reader (issue #285). The structured view keeps the *port* — the
// injectable [ClipboardImageReader] typedef and its `imageReader` widget
// param — but not the `dart:io`-using default: that lives here, in its own
// module, so the view no longer imports the process platform library.

import 'dart:convert';
import 'dart:io';

import 'dart:typed_data';

/// An image read from the clipboard (issue #72): its raw bytes and mime type,
/// sent to the model as a `files` data-URI attachment.
class ClipboardImage {
  const ClipboardImage({required this.bytes, required this.mime});

  /// The image's raw bytes.
  final Uint8List bytes;

  /// The image's mime type (e.g. `image/png`).
  final String mime;
}

/// The outcome of a clipboard image read (issue #72): the clipboard's
/// image, or `null` when there is none — plus, for a read that cannot
/// produce an image, a user-visible [failureMessage] saying how to get one
/// (e.g. the read tool is not installed and how to install it).
class ClipboardImageRead {
  const ClipboardImageRead({this.image, this.failureMessage});

  /// The clipboard's image, or `null` when there is none.
  final ClipboardImage? image;

  /// How to get an image read, to show the user (issue #72), or `null` when
  /// there is nothing to report (a plain "no image").
  final String? failureMessage;
}

/// Reads the clipboard's image (issue #72): no image reads as no [image],
/// and a read that cannot produce one (e.g. the read tool is not installed)
/// reports how to enable it. Injectable so the screen's tests can fake the
/// read.
typedef ClipboardImageReader = Future<ClipboardImageRead> Function();

/// The service's per-attachment decoded image limit (issue #72): the service
/// materializes inline data URLs up to 20 MiB decoded, so an image over it
/// would be rejected — the client pre-checks and reports it instead of
/// leaving a dead token.
const int kMaxClipboardImageBytes = 20 * 1024 * 1024;

/// The image targets the default reader looks for, most preferred first
/// (issue #72); when none of these is offered, any `image/` target is used.
const List<String> _kPreferredImageTargets = [
  'image/png',
  'image/bmp',
  'image/jpeg',
  'image/jpg',
  'image/gif',
];

/// The default clipboard image reader (issue #72): desktop Linux only, with
/// no new package dependency — X11 via `xclip`, Wayland via `wl-paste`. The
/// reader lists the clipboard's targets, picks an image one, and reads its
/// bytes; any other platform, a failing read, or a clipboard with no image
/// reads as no image. A missing tool reports how to install it, so the user
/// can enable image paste.
///
/// This is the `dart:io`-using process-platform default (issue #285): the
/// structured view references it as the fallback for its injectable
/// [ClipboardImageReader], but the `Platform` / `Process` access lives here,
/// not in the view.
Future<ClipboardImageRead> readClipboardImage() async {
  if (!Platform.isLinux || Platform.isAndroid) {
    return const ClipboardImageRead();
  }
  final env = Platform.environment;
  final wayland =
      env.containsKey('WAYLAND_DISPLAY') ||
      env['XDG_SESSION_TYPE'] == 'wayland';
  final tool = wayland ? 'wl-paste' : 'xclip';
  try {
    Future<List<int>> run(List<String> args) async {
      final result = await Process.run(tool, args, stdoutEncoding: null);
      if (result.exitCode != 0) return const <int>[];
      return result.stdout as List<int>;
    }

    final targets = utf8
        .decode(
          await run(
            wayland
                ? const ['--list']
                : const ['-selection', 'clipboard', '-t', 'TARGETS', '-o'],
          ),
        )
        .split('\n')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();

    String? target;
    for (final preferred in _kPreferredImageTargets) {
      if (targets.contains(preferred)) {
        target = preferred;
        break;
      }
    }
    if (target == null) {
      for (final t in targets) {
        if (t.startsWith('image/')) {
          target = t;
          break;
        }
      }
    }
    if (target == null) return const ClipboardImageRead();

    final bytes = await run(
      wayland
          ? ['--type', target]
          : ['-selection', 'clipboard', '-t', target, '-o'],
    );
    if (bytes.isEmpty) return const ClipboardImageRead();
    return ClipboardImageRead(
      image: ClipboardImage(bytes: Uint8List.fromList(bytes), mime: target),
    );
  } on ProcessException {
    // The tool is not installed: report how to enable the read.
    return ClipboardImageRead(
      failureMessage: wayland
          ? 'Clipboard image paste needs wl-paste '
                '(sudo apt install wl-clipboard).'
          : 'Clipboard image paste needs xclip (sudo apt install xclip).',
    );
  } catch (_) {
    return const ClipboardImageRead();
  }
}
