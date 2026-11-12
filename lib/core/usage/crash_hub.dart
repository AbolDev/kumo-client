import 'dart:async' show TimeoutException;
import 'dart:io';

import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:flutter/widgets.dart';

import 'crash_report.dart';

/// True for an error of the network itself: a connection that was reset, timed out, could not be made or
/// failed its handshake. That is the weather, not a fault of the app (the VPN going up or down resets every
/// open socket), so it is not a crash report however it got to the handlers.
bool isNetworkError(Object error) =>
    error is SocketException ||
    error is TlsException ||
    error is HttpException ||
    error is WebSocketException ||
    error is TimeoutException;

/// The name of what was thrown. A release build renames the classes ("yq"), so the ones worth telling
/// apart are named here by what they are; the rest keep the name the build gave them.
String errorKind(Object error) {
  if (error is SocketException) return 'SocketException';
  if (error is HandshakeException) return 'HandshakeException';
  if (error is TlsException) return 'TlsException';
  if (error is HttpException) return 'HttpException';
  if (error is WebSocketException) return 'WebSocketException';
  if (error is TimeoutException) return 'TimeoutException';
  if (error is FileSystemException) return 'FileSystemException';
  if (error is ProcessException) return 'ProcessException';
  if (error is PlatformException) return 'PlatformException';
  if (error is MissingPluginException) return 'MissingPluginException';
  if (error is FormatException) return 'FormatException';
  if (error is FlutterError) return 'FlutterError';
  if (error is StackOverflowError) return 'StackOverflowError';
  if (error is OutOfMemoryError) return 'OutOfMemoryError';
  if (error is ConcurrentModificationError) return 'ConcurrentModificationError';
  if (error is NoSuchMethodError) return 'NoSuchMethodError';
  if (error is TypeError) return 'TypeError';
  if (error is RangeError) return 'RangeError';
  if (error is ArgumentError) return 'ArgumentError';
  if (error is UnsupportedError) return 'UnsupportedError';
  if (error is StateError) return 'StateError';
  if (error is AssertionError) return 'AssertionError';
  return error.runtimeType.toString();
}

/// Where the app's error handlers hand an error: the one [CrashReporter] of the app (set when the app
/// is up). Before that, and with the switch off, an error is simply not reported.
class CrashHub {
  static CrashReporter? sink;

  /// Reports [error] (never throws, never waits).
  static void report(Object error, StackTrace? stack, {String? kind, bool fatal = false, String? message}) {
    final s = sink;
    if (s == null || isNetworkError(error)) return;
    String text;
    try {
      text = message ?? error.toString();
    } catch (_) {
      text = 'unprintable error';
    }
    s.record(kind: kind ?? errorKind(error), message: text, stack: stack, fatal: fatal);
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
