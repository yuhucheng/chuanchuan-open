import 'dart:async';
import 'dart:io';

/// Test-only byte relay. cut() injects TCP loss without revoking either owner.
class ConnectionRelay {
  ConnectionRelay._(this.server);
  final ServerSocket server;
  final sockets = <Socket>{};
  bool closed = false;
  int get port => server.port;
  static Future<ConnectionRelay> open(int targetPort) async {
    final relay = ConnectionRelay._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    relay.server.listen((client) async {
      relay.sockets.add(client);
      Socket remote;
      try {
        remote = await Socket.connect('127.0.0.1', targetPort);
      } catch (_) {
        client.destroy();
        return;
      }
      if (relay.closed) {
        client.destroy();
        remote.destroy();
        return;
      }
      relay.sockets.add(remote);
      void end() {
        client.destroy();
        remote.destroy();
      }

      client.listen(remote.add, onDone: end, onError: (Object _) => end());
      remote.listen(client.add, onDone: end, onError: (Object _) => end());
      unawaited(client.done.catchError((Object _) {}));
      unawaited(remote.done.catchError((Object _) {}));
    });
    return relay;
  }

  void cut() {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
  }

  Future<void> close() async {
    closed = true;
    cut();
    await server.close();
  }
}
