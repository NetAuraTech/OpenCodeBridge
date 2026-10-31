/// Parses the tunnel URL entered in Settings (issue #23).
///
/// A bare hostname (no scheme) is treated as `https`: the tunnel is served
/// by Cloudflare over TLS, and the hostname alone is what a user naturally
/// types. An empty value stays hostless, so the caller sees the "set a
/// tunnel URL" state rather than a fake host.
Uri parseTunnelUrl(String raw) {
  final value = raw.trim();
  return Uri.parse(
    value.contains('://') || value.isEmpty ? value : 'https://$value',
  );
}
