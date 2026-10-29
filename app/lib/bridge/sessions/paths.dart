import 'dart:io';

/// The user's home directory, for the bridge's per-user config/state paths.
/// Server mode is Linux-host only (ADR-0002), so `HOME` is the reliable source.
String homeDirectory() => Platform.environment['HOME'] ?? '/';
