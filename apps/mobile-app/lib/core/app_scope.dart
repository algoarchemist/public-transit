import 'package:flutter/material.dart';

import 'api_client.dart';

/// Makes the single [ApiClient] reachable from any screen. Plain [InheritedWidget]
/// — the client is immutable, so there is nothing to notify about.
class ApiScope extends InheritedWidget {
  const ApiScope({super.key, required this.client, required super.child});

  final ApiClient client;

  static ApiClient of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ApiScope>();
    assert(scope != null, 'No ApiScope above this widget');
    return scope!.client;
  }

  @override
  bool updateShouldNotify(ApiScope oldWidget) => client != oldWidget.client;
}
