/// Compile-time client configuration. Override with --dart-define=WS_URL=...
class ClientConfig {
  const ClientConfig({
    this.wsUrl = const String.fromEnvironment(
      'WS_URL',
      defaultValue: 'ws://localhost:8080/ws',
    ),
    this.devLatencyMs = 0,
    this.devLossPct = 0,
  });

  final String wsUrl;
  final int devLatencyMs;
  final int devLossPct;
}
