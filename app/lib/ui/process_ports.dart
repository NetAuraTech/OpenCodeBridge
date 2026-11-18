// The process-platform concerns of the structured view's local `/` commands
// (issue #285), behind small injectable ports: the view's `/exit` calls an
// [exitApp] callback instead of `exit` directly, and its `/debug` reads the
// OS label from an [osLabel] callback instead of `Platform.operatingSystem`.
// The defaults are the real `dart:io` process calls; injecting fakes keeps
// the view importable without the process platform library, and keeps the
// tests off a hard exit and a real platform read.

import 'dart:io';

/// The structured view's `/exit` local command (issue #285): the view calls
/// this instead of `exit(0)` directly. The default is the real hard exit; a
/// test injects a recorder so the command is observable without killing the
/// test process.
typedef ExitApp = void Function();

/// The default `/exit`: the real hard exit.
void exitApp() => exit(0);

/// The OS label the structured view's `/debug` shows (issue #285): the view
/// reads this instead of `Platform.operatingSystem` directly. The default is
/// the real platform's label; a test injects a fixed value.
typedef OsLabel = String Function();

/// The default OS label: the process platform's own.
String osLabel() => Platform.operatingSystem;
