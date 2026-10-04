import 'package:meta/meta.dart';

import 'bindings/types/aliases.dart';

mixin Listenable {
  final _listeners = <VoidCallback>[];

  void addListener(VoidCallback listener) => _listeners.add(listener);

  @protected
  void clearListeners() => _listeners.clear();

  @protected
  void notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  void removeListener(VoidCallback listener) => _listeners.remove(listener);
}
