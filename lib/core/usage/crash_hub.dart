import 'package:flutter/widgets.dart';

import 'crash_report.dart';

/// Where the app's error handlers hand an error: the one [CrashReporter] of the app (set when the app
/// is up). Before that, and with the switch off, an error is simply not reported.
class CrashHub {
  static CrashReporter? sink;

  /// Reports [error] (never throws, never waits).
  static void report(Object error, StackTrace? stack, {String? kind, bool fatal = false, String? message}) {
    final s = sink;
    if (s == null) return;
    String text;
    try {
      text = message ?? error.toString();
    } catch (_) {
      text = 'unprintable error';
    }
    s.record(kind: kind ?? error.runtimeType.toString(), message: text, stack: stack, fatal: fatal);
  }
}

/// Keeps the name of the page the user is on: the route names set where a page is opened, and
/// "dialog" for windows and sheets (written as "page#dialog"). Never an id or a query value.
class RouteTracker extends NavigatorObserver {
  final _stack = <String>[];

  String _name(Route<dynamic> route) {
    final n = route.settings.name;
    if (n != null && n.isNotEmpty) return n;
    return route is PageRoute ? 'page' : 'dialog';
  }

  /// The page on top, e.g. "/LogsPage" or "/#dialog"; null before any.
  String? get current {
    if (_stack.isEmpty) return null;
    var i = _stack.length - 1;
    var dialog = false;
    while (i > 0 && _stack[i] == 'dialog') {
      dialog = true;
      i--;
    }
    final page = _stack[i] == 'dialog' ? '/' : _stack[i];
    return dialog ? '$page#dialog' : page;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _stack.add(_name(route));

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_stack.isNotEmpty) _stack.removeLast();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_stack.isNotEmpty) _stack.removeLast();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (_stack.isNotEmpty) _stack.removeLast();
    if (newRoute != null) _stack.add(_name(newRoute));
  }
}
