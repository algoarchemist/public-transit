/// Compile-time config, overridable at build/run time, e.g.:
///   flutter run --dart-define=MQTT_BROKER_HOST=192.168.1.50
class AppConfig {
  /// 10.0.2.2 is the Android emulator's alias for the host machine's localhost —
  /// the right default when EMQX is running via docker-compose on your dev machine.
  /// Override for a real device on the same network, or a deployed broker.
  static const mqttBrokerHost = String.fromEnvironment(
    'MQTT_BROKER_HOST',
    defaultValue: '10.0.2.2',
  );
  static const mqttBrokerPort = int.fromEnvironment('MQTT_BROKER_PORT', defaultValue: 1883);
}
