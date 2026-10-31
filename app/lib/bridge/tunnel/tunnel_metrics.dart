/// The registered edge connections in a cloudflared `--metrics` body
/// (Prometheus text format).
///
/// "Registered" is the `cloudflared_tunnel_ha_connections` gauge (the
/// number of active HA connections to the Cloudflare edge, per the Cloudflare
/// tunnel metrics docs): > 0 is what separates "cloudflared runs" from
/// "actually connected to the edge".
int parseRegisteredConnections(String metricsBody) {
  var connections = 0;
  for (final line in metricsBody.split('\n')) {
    if (line.startsWith('#')) continue;
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 2) continue;
    // The metric name may carry a `{…}` label block.
    final name = fields[0].split('{').first;
    if (name != 'cloudflared_tunnel_ha_connections') continue;
    final value = int.tryParse(fields[1]);
    if (value != null) connections += value;
  }
  return connections;
}
