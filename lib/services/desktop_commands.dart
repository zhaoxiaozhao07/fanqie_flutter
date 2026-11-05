/// Route-owned handlers keep native menu commands aligned with the active page.
class DesktopCommands {
  static final Map<Object, bool Function(String)> _handlers = {};

  static void register(Object owner, bool Function(String)? handler) {
    if (handler == null) {
      _handlers.remove(owner);
    } else {
      _handlers[owner] = handler;
    }
  }

  static bool dispatch(String command) {
    for (final handler in _handlers.values.toList().reversed) {
      if (handler(command)) return true;
    }
    return false;
  }
}
