import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/remote_scrub_controller.dart';

const _right = LogicalKeyboardKey.arrowRight;
const _left = LogicalKeyboardKey.arrowLeft;

typedef _Action = RemoteScrubAction;
typedef _Direction = RemoteScrubDirection;

const _holdDelay = RemoteScrubController.holdDelay;
const _speeds = RemoteScrubController.speeds;
const _second = Duration(seconds: 1);

Duration _seconds(int value) => Duration(seconds: value);

/// A controller over a position and a length the test can change, with every
/// move and notification recorded.
class _Rig {
  _Rig({Duration? pos, Duration? len})
    : pos = pos ?? _seconds(60),
      len = len ?? _seconds(600) {
    controller = RemoteScrubController(
      position: () => this.pos,
      duration: () => this.len,
      onMove: moves.add,
    )..addListener(() => notifications++);
  }

  Duration pos;
  Duration len;
  final moves = <Duration>[];
  var notifications = 0;
  late final RemoteScrubController controller;

  RemoteScrubDirection? get direction => controller.direction;
  int get level => controller.level;
  bool get isScrubbing => controller.isScrubbing;
  Duration get target => moves.last;

  RemoteScrubAction down(
    LogicalKeyboardKey key, {
    bool fromSeekbar = true,
    bool controlsVisible = true,
    bool skipButtonFocused = false,
  }) => _send(
    KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.abort,
      logicalKey: key,
      timeStamp: Duration.zero,
    ),
    fromSeekbar,
    controlsVisible,
    skipButtonFocused,
  );

  RemoteScrubAction repeat(LogicalKeyboardKey key) => _send(
    KeyRepeatEvent(
      physicalKey: PhysicalKeyboardKey.abort,
      logicalKey: key,
      timeStamp: Duration.zero,
    ),
    true,
    true,
    false,
  );

  RemoteScrubAction up(
    LogicalKeyboardKey key, {
    bool fromSeekbar = true,
    bool controlsVisible = true,
  }) => _send(
    KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.abort,
      logicalKey: key,
      timeStamp: Duration.zero,
    ),
    fromSeekbar,
    controlsVisible,
    false,
  );

  RemoteScrubAction _send(
    KeyEvent event,
    bool fromSeekbar,
    bool controlsVisible,
    bool skipButtonFocused,
  ) => controller.handleKey(
    event,
    fromSeekbar: fromSeekbar,
    controlsVisible: controlsVisible,
    skipButtonFocused: skipButtonFocused,
  );

  /// A press and release of [key], as a scrub sees a further click.
  void press(LogicalKeyboardKey key) {
    down(key);
    up(key);
  }

  /// Holds [key] past the hold delay, then lets go: a running scrub.
  void startHold(FakeAsync async, LogicalKeyboardKey key) {
    down(key);
    async.elapse(_holdDelay);
    up(key);
  }
}

void main() {
  test('a click skips on release and never scrubs', () {
    fakeAsync((async) {
      final rig = _Rig();

      expect(rig.down(_right), _Action.consume);
      async.elapse(_holdDelay ~/ 3);
      expect(rig.up(_right), _Action.clickOnSeekbar);
      expect(rig.controller.lastPressDirection, _Direction.forward);

      expect(rig.down(_left, controlsVisible: false), _Action.revealControls);
      async.elapse(_holdDelay ~/ 3);
      expect(rig.up(_left, controlsVisible: false), _Action.clickFromHidden);
      expect(rig.controller.lastPressDirection, _Direction.backward);

      async.elapse(_holdDelay * 2);
      expect(rig.isScrubbing, isFalse);
      expect(rig.moves, isEmpty);
      rig.controller.dispose();
    });
  });

  test('a hold starts level 1 from the position', () {
    fakeAsync((async) {
      final rig = _Rig(pos: _seconds(60), len: _seconds(600));

      rig.down(_right);
      async.elapse(_holdDelay - const Duration(milliseconds: 1));
      expect(rig.isScrubbing, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(rig.isScrubbing, isTrue);
      expect(rig.level, 1);
      expect(rig.direction, _Direction.forward);
      expect(rig.moves, [_seconds(60)]);

      // Let go before the first hold step, so the scrub stays at level 1.
      rig.up(_right);
      async.elapse(_second);
      expect(rig.target, _seconds(60 + _speeds[0]));
      rig.controller.dispose();
    });
  });

  test('releasing the key keeps the scrub running', () {
    fakeAsync((async) {
      final rig = _Rig(pos: _seconds(60), len: _seconds(600));
      rig.down(_right);
      async.elapse(_holdDelay + _second ~/ 2);
      final before = rig.target;

      expect(rig.up(_right), _Action.consume);
      expect(rig.isScrubbing, isTrue);
      // A release with no press of its own, such as Left while Right is held,
      // must not reach the player's release logic, which would commit.
      expect(rig.up(_left), _Action.consume);
      expect(rig.isScrubbing, isTrue);
      async.elapse(_second);
      expect(rig.target, before + _seconds(_speeds[0]));
      rig.controller.dispose();
    });
  });

  test('levels go up to the cap, down, and turn around', () {
    fakeAsync((async) {
      final top = _speeds.length;
      final rig = _Rig(pos: _seconds(10), len: _seconds(100000));
      rig.startHold(async, _right);
      expect(rig.notifications, 1);

      // Further presses the same way: up to the cap, then nothing changes.
      for (var i = 0; i < top; i++) {
        rig.press(_right);
      }
      expect(rig.level, top);
      expect(rig.direction, _Direction.forward);
      expect(rig.notifications, 1 + top - 1);

      // The other way: one level down per press, then it turns around.
      for (var i = 0; i < top - 1; i++) {
        rig.press(_left);
      }
      expect(rig.level, 1);
      expect(rig.direction, _Direction.forward);
      rig.press(_left);
      expect(rig.level, 1);
      expect(rig.direction, _Direction.backward);
      expect(rig.notifications, 1 + (top - 1) + (top - 1) + 1);

      // Rewind and Fast forward do the same without a Left or Right press.
      void key(LogicalKeyboardKey logical) {
        expect(rig.down(logical), RemoteScrubAction.consume);
      }

      for (var i = 0; i < top - 1; i++) {
        key(LogicalKeyboardKey.mediaRewind);
      }
      expect(rig.level, top);
      expect(rig.direction, _Direction.backward);
      key(LogicalKeyboardKey.mediaRewind);
      expect(rig.level, top);
      for (var i = 0; i < top - 1; i++) {
        key(LogicalKeyboardKey.mediaFastForward);
      }
      expect(rig.level, 1);
      expect(rig.direction, _Direction.backward);
      key(LogicalKeyboardKey.mediaFastForward);
      expect(rig.level, 1);
      expect(rig.direction, _Direction.forward);
      rig.controller.dispose();
    });
  });

  test('the target moves at the speed of the level', () {
    fakeAsync((async) {
      final rig = _Rig(pos: _seconds(60), len: _seconds(100000));
      rig.down(_right);
      async.elapse(_holdDelay);
      final start = rig.target;
      rig.up(_right);

      async.elapse(_second);
      final afterLevel1 = rig.target;
      expect(afterLevel1 - start, _seconds(_speeds[0]));

      rig.press(_right);
      async.elapse(_second);
      expect(rig.target - afterLevel1, _seconds(_speeds[1]));
      rig.controller.dispose();
    });
  });

  test('the end stops the scrub and a press restarts it', () {
    fakeAsync((async) {
      final len = _seconds(10000);
      final rig = _Rig(pos: len - _second, len: len);

      rig.down(_right);
      async.elapse(_holdDelay + _second);
      expect(rig.target, len);
      expect(rig.level, 0);
      expect(rig.isScrubbing, isTrue);
      rig.up(_right);

      final moves = rig.moves.length;
      async.elapse(_second);
      expect(rig.moves.length, moves);

      rig.press(_left);
      expect(rig.level, 1);
      expect(rig.direction, _Direction.backward);
      async.elapse(_second);
      expect(rig.target, len - _seconds(_speeds[0]));
      rig.controller.dispose();
    });
  });

  test('the start stops a rewind at zero', () {
    fakeAsync((async) {
      final rig = _Rig(pos: _seconds(3), len: _seconds(600));

      rig.down(_left);
      async.elapse(_holdDelay + _seconds(10));
      expect(rig.target, Duration.zero);
      expect(rig.moves.every((move) => move >= Duration.zero), isTrue);
      expect(rig.level, 0);
      expect(rig.isScrubbing, isTrue);
      rig.controller.dispose();
    });
  });

  test('OK and Play finish a scrub, Pause finishes it paused, Back is left to '
      'the player', () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.startHold(async, _right);

      for (final key in [
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.gameButtonA,
        LogicalKeyboardKey.mediaPlay,
        LogicalKeyboardKey.mediaPlayPause,
      ]) {
        expect(rig.down(key), _Action.finishPlay, reason: key.debugName);
      }
      expect(rig.down(LogicalKeyboardKey.mediaPause), _Action.finishPause);
      expect(rig.down(LogicalKeyboardKey.arrowUp), _Action.consume);
      expect(rig.down(LogicalKeyboardKey.arrowDown), _Action.consume);
      expect(rig.down(LogicalKeyboardKey.goBack), _Action.none);

      // Repeats of the scrub's keys are swallowed and a release is not its
      // business.
      expect(rig.repeat(LogicalKeyboardKey.select), _Action.consume);
      expect(rig.repeat(LogicalKeyboardKey.goBack), _Action.none);
      expect(rig.up(LogicalKeyboardKey.select), _Action.none);
      rig.controller.dispose();
    });
  });

  test('stop ends a hold in progress and a running scrub', () {
    fakeAsync((async) {
      final rig = _Rig();

      rig.down(_right);
      async.elapse(_holdDelay ~/ 2);
      rig.controller.stop();
      async.elapse(_holdDelay * 2);
      expect(rig.isScrubbing, isFalse);
      expect(rig.moves, isEmpty);
      expect(rig.up(_right), _Action.none);

      rig.startHold(async, _right);
      expect(rig.isScrubbing, isTrue);
      rig.controller.stop();
      final moves = rig.moves.length;
      async.elapse(_seconds(5));
      expect(rig.moves.length, moves);
      expect(rig.isScrubbing, isFalse);
      expect(rig.level, 0);
      rig.controller.dispose();
    });
  });

  test('the skip button and the transport buttons keep Left and Right', () {
    fakeAsync((async) {
      final rig = _Rig();

      expect(rig.down(_right, skipButtonFocused: true), _Action.none);
      expect(
        rig.down(_left, fromSeekbar: false, controlsVisible: true),
        _Action.none,
      );
      async.elapse(_holdDelay * 2);
      expect(rig.isScrubbing, isFalse);
      expect(rig.moves, isEmpty);
      expect(rig.up(_right), _Action.none);
      expect(rig.up(_left), _Action.none);
      rig.controller.dispose();
    });
  });

  test('without a length a hold does not scrub and stays a click', () {
    fakeAsync((async) {
      final rig = _Rig(len: Duration.zero);

      rig.down(_right);
      async.elapse(_holdDelay * 2);
      expect(rig.isScrubbing, isFalse);
      expect(rig.moves, isEmpty);
      expect(rig.up(_right), _Action.clickOnSeekbar);
      rig.controller.dispose();
    });
  });

  test('listeners hear each real change once and nothing after dispose', () {
    fakeAsync((async) {
      final len = _seconds(10000);
      final rig = _Rig(pos: len - _second, len: len);

      rig.down(_right);
      async.elapse(_holdDelay);
      expect(rig.notifications, 1, reason: 'start');

      async.elapse(_second);
      expect(rig.level, 0);
      expect(rig.notifications, 2, reason: 'stopped at the end');
      rig.up(_right);

      rig.press(_left);
      expect(rig.notifications, 3, reason: 'a press away from the end');
      rig.press(_left);
      expect(rig.notifications, 4, reason: 'one level up');
      async.elapse(_second);
      expect(rig.notifications, 4, reason: 'moving is not a change');

      rig.controller.stop();
      expect(rig.notifications, 5, reason: 'stop');
      rig.controller.stop();
      expect(rig.notifications, 5, reason: 'stop when not scrubbing');

      rig.controller.dispose();
      expect(rig.notifications, 5, reason: 'dispose');
    });
  });

  test('a held key climbs one level each step', () {
    fakeAsync((async) {
      final top = _speeds.length;
      final rig = _Rig(pos: _seconds(10), len: _seconds(100000));

      rig.down(_right);
      async.elapse(_holdDelay);
      expect(rig.level, 1);
      expect(rig.notifications, 1);

      for (var level = 2; level <= top; level++) {
        async.elapse(RemoteScrubController.stepEvery);
        expect(rig.level, level);
        expect(rig.notifications, level);
      }

      async.elapse(RemoteScrubController.stepEvery * 2);
      expect(rig.level, top, reason: 'capped');
      expect(rig.notifications, top);
      expect(rig.direction, _Direction.forward);
      rig.controller.dispose();
    });
  });

  test('letting go after a step stops the scrub and before a step runs on', () {
    fakeAsync((async) {
      final rig = _Rig(pos: _seconds(10), len: _seconds(100000));

      // Before the first step: the short hold runs on.
      rig.down(_right);
      async.elapse(_holdDelay + RemoteScrubController.stepEvery ~/ 2);
      expect(rig.up(_right), _Action.consume);
      expect(rig.level, 1);
      final running = rig.moves.length;
      async.elapse(_second);
      expect(rig.moves.length, greaterThan(running));
      rig.controller.stop();

      // After a step: the scrub stops where it is and the player sees the
      // release.
      rig.down(_right);
      async.elapse(_holdDelay + RemoteScrubController.stepEvery);
      expect(rig.level, 2);
      expect(rig.up(_right), _Action.none);
      expect(rig.isScrubbing, isTrue);
      expect(rig.level, 0);
      expect(rig.controller.atEnd, isFalse);
      final stopped = rig.moves.length;
      async.elapse(_seconds(5));
      expect(rig.moves.length, stopped);

      rig.press(_right);
      expect(rig.level, 1);
      expect(rig.direction, _Direction.forward);
      rig.controller.dispose();
    });
  });

  test('a press held during a scrub steps too', () {
    fakeAsync((async) {
      const step = RemoteScrubController.stepEvery;
      final rig = _Rig(pos: _seconds(10), len: _seconds(100000));
      rig.startHold(async, _right);
      expect(rig.level, 1);

      rig.down(_right);
      expect(rig.level, 2);
      async.elapse(step);
      expect(rig.level, 3);
      expect(rig.up(_right), _Action.none);
      expect(rig.level, 0);

      // From level 2, a held Left goes down, turns round, then speeds up.
      rig.press(_right);
      rig.press(_right);
      expect(rig.level, 2);
      rig.down(_left);
      expect(rig.level, 1);
      expect(rig.direction, _Direction.forward);
      async.elapse(step);
      expect(rig.level, 1);
      expect(rig.direction, _Direction.backward);
      async.elapse(step);
      expect(rig.level, 2);
      expect(rig.direction, _Direction.backward);
      expect(rig.up(_left), _Action.none);
      expect(rig.level, 0);
      rig.controller.dispose();
    });
  });

  test('a key held into the end changes nothing more', () {
    fakeAsync((async) {
      final len = _seconds(10000);
      final rig = _Rig(pos: len - _second, len: len);

      rig.down(_right);
      async.elapse(_holdDelay + _second);
      expect(rig.level, 0);
      expect(rig.controller.atEnd, isTrue);
      final notifications = rig.notifications;
      final moves = rig.moves.length;

      async.elapse(RemoteScrubController.stepEvery * 3);
      expect(rig.level, 0);
      expect(rig.controller.atEnd, isTrue);
      expect(rig.notifications, notifications);
      expect(rig.moves.length, moves);
      rig.controller.dispose();
    });
  });
}
