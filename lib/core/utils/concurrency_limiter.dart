import 'dart:async';

/// Limits concurrent asynchronous task execution to [maxConcurrent].
///
/// Ensures socket connections and CPU are not overwhelmed by running
/// unbounded parallel operations.
class ConcurrencyLimiter {
  final int maxConcurrent;
  int _running = 0;
  final List<Completer<void>> _waiters = [];

  ConcurrencyLimiter(this.maxConcurrent) {
    if (maxConcurrent < 1) {
      throw ArgumentError.value(
        maxConcurrent,
        'maxConcurrent',
        'Must be at least 1',
      );
    }
  }

  int get runningCount => _running;
  int get queueLength => _waiters.length;

  Future<T> run<T>(Future<T> Function() task) async {
    while (_running >= maxConcurrent) {
      final completer = Completer<void>();
      _waiters.add(completer);
      await completer.future;
    }

    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      }
    }
  }
}
