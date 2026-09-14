/// In-app log.
///
/// Rule 9: log errors instead of silently handling them. Everything the BLE
/// layer does — and in particular everything that fails — lands here and stays
/// visible in the developer section, rather than disappearing into a caught
/// exception or a debug print the user never sees.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;

enum LogLevel {
  debug('DEBUG'),
  info('INFO'),
  warning('WARN'),
  error('ERROR');

  const LogLevel(this.label);

  final String label;
}

class LogEntry {
  LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  final DateTime timestamp;
  final LogLevel level;
  final String tag;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  /// Full text including the error, for copy-to-clipboard.
  String get fullText {
    final buffer = StringBuffer()
      ..write(timestamp.toIso8601String())
      ..write(' [${level.label}] ')
      ..write('$tag: $message');
    if (error != null) buffer.write('\n  error: $error');
    if (stackTrace != null) buffer.write('\n$stackTrace');
    return buffer.toString();
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toUtc().toIso8601String(),
        'level': level.label,
        'tag': tag,
        'message': message,
        'error': error?.toString(),
        'stackTrace': stackTrace?.toString(),
      };
}

/// A bounded in-memory log with a broadcast stream.
///
/// Bounded because a BLE session can generate a great many entries and an
/// unbounded buffer would eventually take the app down; [maxEntries] is large
/// enough that nothing interesting is lost within a session.
class AppLogger {
  AppLogger({this.maxEntries = 5000});

  final int maxEntries;
  final ListQueue<LogEntry> _entries = ListQueue<LogEntry>();
  final StreamController<LogEntry> _controller =
      StreamController<LogEntry>.broadcast();

  /// Newest last.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  Stream<LogEntry> get stream => _controller.stream;

  void debug(String tag, String message) => _add(LogLevel.debug, tag, message);

  void info(String tag, String message) => _add(LogLevel.info, tag, message);

  void warning(String tag, String message, [Object? error]) =>
      _add(LogLevel.warning, tag, message, error);

  void error(String tag, String message, [Object? error, StackTrace? stack]) =>
      _add(LogLevel.error, tag, message, error, stack);

  void clear() => _entries.clear();

  void _add(
    LogLevel level,
    String tag,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) {
    final entry = LogEntry(
      timestamp: DateTime.now().toUtc(),
      level: level,
      tag: tag,
      message: message,
      error: error,
      stackTrace: stack,
    );
    _entries.addLast(entry);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    if (!_controller.isClosed) _controller.add(entry);
    developer.log(
      message,
      name: tag,
      level: switch (level) {
        LogLevel.debug => 500,
        LogLevel.info => 800,
        LogLevel.warning => 900,
        LogLevel.error => 1000,
      },
      error: error,
      stackTrace: stack,
    );
  }

  Future<void> dispose() => _controller.close();
}
