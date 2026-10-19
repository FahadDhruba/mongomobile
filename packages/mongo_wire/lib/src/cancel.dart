import 'dart:async';

import 'errors.dart';

/// Lets a caller abort a running operation, such as a slow query.
///
/// Cancelling closes the connection the operation runs on, so the request
/// returns at once with a [MongoCancelledError]. The client also asks the
/// server to kill the operation where it can.
class CancelToken {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }

  /// Throws [MongoCancelledError] if already cancelled.
  void throwIfCancelled() {
    if (isCancelled) throw MongoCancelledError();
  }
}
