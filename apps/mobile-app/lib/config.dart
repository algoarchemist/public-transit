import 'package:flutter/foundation.dart' show kIsWeb;

/// Compile-time config, overridable at build/run time, e.g.:
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.50:3000
class AppConfig {
  /// 10.0.2.2 is the Android emulator's alias for the host machine's localhost.
  /// A browser (`flutter run -d chrome`, the fast preview loop) talks to real
  /// localhost instead, so the default has to switch on platform rather than being
  /// one constant. Override either with --dart-define for a physical device.
  static const _hostOverride = String.fromEnvironment('BACKEND_HOST');

  static String get _host {
    if (_hostOverride.isNotEmpty) return _hostOverride;
    return kIsWeb ? 'localhost' : '10.0.2.2';
  }

  /// api-gateway (NestJS). Routes, stops, trip lifecycle.
  static String get apiBaseUrl {
    const override = String.fromEnvironment('API_BASE_URL');
    return override.isNotEmpty ? override : 'http://$_host:3000/api';
  }

  /// stream-processor's Socket.IO gateway — the live `bus:update` feed.
  static String get socketUrl {
    const override = String.fromEnvironment('SOCKET_URL');
    return override.isNotEmpty ? override : 'http://$_host:4001';
  }

  /// EMQX. The driver transmitter publishes `gps/{busId}/ping` here.
  static String get mqttBrokerHost => _host;
  static const mqttBrokerPort = int.fromEnvironment('MQTT_BROKER_PORT', defaultValue: 1883);

  /// A browser cannot open a raw TCP socket, so Flutter web has to reach the broker
  /// over MQTT-on-WebSocket (EMQX's :8083 listener — see docker-compose.yml).
  static const mqttWebSocketPort = int.fromEnvironment('MQTT_WS_PORT', defaultValue: 8083);
  static String get mqttWebSocketUrl => 'ws://$_host:$mqttWebSocketPort/mqtt';

  /// Map centre when the device has no location fix yet — the real centroid of the
  /// ingested Chandigarh-tricity network, so the first frame shows the actual
  /// service area rather than the middle of the ocean.
  static const fallbackLat = 30.7333;
  static const fallbackLon = 76.7794;
}
