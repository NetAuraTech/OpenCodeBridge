/// The desktop launch mode, chosen at every launch (spec section 3):
///
/// - [AppMode.server] — the app hosts the embedded bridge on this machine
///   (localhost only, remote through the tunnel).
/// - [AppMode.client] — the app is a pure client connecting to a bridge at
///   the tunnel URL from Settings.
///
/// Android has no choice: it is always [AppMode.client].
enum AppMode { server, client }
