import 'package:fake_async/fake_async.dart';
import 'package:flterm/src/widgets/compression_scheduler.dart';
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' show TerminalCompressionResult;

void main() {
  group('CompressionScheduler', () {
    CompressionScheduler createScheduler(
      _CompressionBackend backend,
      _IdleQueue idle,
    ) {
      final subject = CompressionScheduler(
        readActivity: () => backend.activity,
        compress: backend.compress,
        scheduleIdle: idle.schedule,
      );
      addTearDown(subject.dispose);
      return subject;
    }

    group('notifyActivity', () {
      test('ignores unchanged activity without pending compression', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);

          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));

          expect(idle.length, 0);
        });
      });

      test('postpones scheduled compression after unchanged activity', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          subject.schedule();
          async.elapse(const Duration(milliseconds: 200));

          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 50));

          expect(idle.length, 0);
        });
      });

      test('waits for terminal activity to become idle', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);

          backend.activity = 1;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 249));

          expect(idle.length, 0);
        });
      });

      test('queues compression after the idle delay', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);

          backend.activity = 1;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));

          expect(idle.length, 1);
        });
      });

      test('restarts the idle delay after more activity', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 200));

          backend.activity = 2;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 249));

          expect(idle.length, 0);
        });
      });

      test('invalidates a queued step after more activity', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));

          backend.activity = 2;
          subject.notifyActivity();
          idle.runNext();

          expect(backend.compressionCount, 0);
        });
      });

      test('invalidates a queued step after unchanged terminal activity', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          subject.schedule();
          async.elapse(const Duration(milliseconds: 250));

          subject.notifyActivity();
          idle.runNext();

          expect(backend.compressionCount, 0);
        });
      });
    });

    group('compression', () {
      test('runs one bounded step when idle', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));

          idle.runNext();

          expect(backend.compressionCount, 1);
        });
      });

      test('continues pending work after yielding', () {
        fakeAsync((async) {
          final backend = _CompressionBackend(
            results: const [.pending, .complete],
          );
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));
          idle.runNext();

          async.elapse(const Duration(milliseconds: 1));
          idle.runNext();

          expect(backend.compressionCount, 2);
        });
      });

      test('waits one millisecond before continuing pending work', () {
        fakeAsync((async) {
          final backend = _CompressionBackend(
            results: const [.pending, .complete],
          );
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));
          idle.runNext();

          async.elapse(const Duration(microseconds: 999));

          expect(idle.length, 0);
        });
      });

      test('returns pending work to idle delay after terminal activity', () {
        fakeAsync((async) {
          final backend = _CompressionBackend(
            results: const [.pending, .complete],
          );
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));
          idle.runNext();

          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 249));

          expect(idle.length, 0);
        });
      });

      test('stops after compression completes', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));
          idle.runNext();

          async.elapse(const Duration(seconds: 1));

          expect(idle.length, 0);
        });
      });

      test('stops scheduling on unsupported targets', () {
        fakeAsync((async) {
          final backend = _CompressionBackend(results: const [.unsupported]);
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));
          idle.runNext();

          backend.activity = 2;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));

          expect(idle.length, 0);
        });
      });
    });

    group('cancel', () {
      test('cancels the idle delay', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.notifyActivity();

          subject.cancel();
          async.elapse(const Duration(milliseconds: 250));

          expect(idle.length, 0);
        });
      });

      test('invalidates queued work', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));

          subject.cancel();
          idle.runNext();

          expect(backend.compressionCount, 0);
        });
      });
    });

    group('dispose', () {
      test('cancels the idle delay', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.notifyActivity();

          subject.dispose();
          async.elapse(const Duration(milliseconds: 250));

          expect(idle.length, 0);
        });
      });

      test('invalidates queued work', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));

          subject.dispose();
          idle.runNext();

          expect(backend.compressionCount, 0);
        });
      });

      test('is idempotent', () {
        final backend = _CompressionBackend();
        final idle = _IdleQueue();
        final subject = createScheduler(backend, idle);

        subject.dispose();

        expect(subject.dispose, returnsNormally);
      });

      test('ignores activity after disposal', () {
        fakeAsync((async) {
          final backend = _CompressionBackend();
          final idle = _IdleQueue();
          final subject = createScheduler(backend, idle);
          backend.activity = 1;
          subject.dispose();

          subject.notifyActivity();
          async.elapse(const Duration(milliseconds: 250));

          expect(idle.length, 0);
        });
      });
    });
  });
}

final class _CompressionBackend {
  _CompressionBackend({
    List<TerminalCompressionResult> results = const [.complete],
  }) : _results = List.of(results),
       activity = 0,
       compressionCount = 0;

  final List<TerminalCompressionResult> _results;
  int activity;
  int compressionCount;

  TerminalCompressionResult compress() {
    compressionCount++;
    return _results.removeAt(0);
  }
}

final class _IdleQueue {
  final List<VoidCallback> _callbacks = [];

  int get length => _callbacks.length;

  void schedule(VoidCallback callback) => _callbacks.add(callback);

  void runNext() => _callbacks.removeAt(0)();
}
