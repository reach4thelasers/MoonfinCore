import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../util/focus/dpad_keys.dart';

/// Which way a scrub runs.
enum RemoteScrubDirection { forward, backward }

/// What the player does with a key after [RemoteScrubController.handleKey].
enum RemoteScrubAction {
  /// Not the scrub's key: the player handles it as before.
  none,

  /// The scrub took the key; the player does nothing else.
  consume,

  /// A Left or Right press began with the controls hidden: show them and focus
  /// the seek bar.
  revealControls,

  /// A click that began with the controls hidden: skip as the hidden-controls
  /// press does today.
  clickFromHidden,

  /// A click on the seek bar: skip as the seek bar does today.
  clickOnSeekbar,

  /// Finish the scrub and play from its target.
  finishPlay,

  /// Finish the scrub and stay paused at its target.
  finishPause,
}

/// Scrubs with a TV remote's Left and Right keys the way the Apple TV app does.
///
/// A press released before [holdDelay] is a click and the player skips as
/// before. A press held past it starts a scrub at level 1. Letting go keeps the
/// scrub running. Each further press the same way goes one level faster, the
/// other way one level slower, and from level 1 it turns around. Keeping the
/// key down counts as another press every [stepEvery]. Letting go after such a
/// step stops the scrub where it is, and the player then treats the release as
/// it does today. Fast forward and Rewind do the same while a scrub runs. At
/// the start or the end the scrub stops and waits. OK or Play finishes it and
/// plays, Pause finishes it paused, and the player drops it on Back.
///
/// The controller only moves a target and reports it through [onMove]. It never
/// seeks, so the player seeks once, when the scrub finishes.
class RemoteScrubController extends ChangeNotifier {
  RemoteScrubController({
    required this.position,
    required this.duration,
    required this.onMove,
  });

  /// How long a press must last to scrub. Longer than Android's 400 ms long
  /// press, shorter than Apple TV's, so a quick click never scrubs.
  static const holdDelay = Duration(milliseconds: 600);

  /// Seconds of video per second at each level, level 1 first. The first four
  /// are the Apple TV app's. The fifth is today's hold speed at the default
  /// skip.
  static const speeds = <int>[8, 24, 48, 96, 600];

  /// How often a running scrub moves the target.
  static const tick = Duration(milliseconds: 100);

  /// While Left or Right stays down in a scrub, each period counts as one more
  /// press of it, so a held key climbs the levels.
  static const stepEvery = Duration(seconds: 1);

  /// Where a scrub starts, read when the hold begins.
  final ValueGetter<Duration> position;

  /// The length of what is playing, read when the hold begins.
  final ValueGetter<Duration> duration;

  /// Gets each new target, the first when a scrub starts.
  final ValueChanged<Duration> onMove;

  RemoteScrubDirection? _direction;
  int _level = 0;
  Duration _target = Duration.zero;
  Duration _length = Duration.zero;
  Timer? _clock;
  int _lastTick = 0;
  Timer? _holdTimer;
  RemoteScrubDirection? _pressed;
  bool _pressIsClick = false;
  bool _pressFromHidden = false;
  RemoteScrubDirection? _lastPressDirection;
  Timer? _stepTimer;

  // The press in hand has made a hold step.
  bool _pressStepped = false;

  bool get isScrubbing => _direction != null;

  RemoteScrubDirection? get direction => _direction;

  /// 1 to [speeds].length, or 0 while stopped.
  int get level => _level;

  /// Whether the scrub is stopped at the start or the end.
  bool get atEnd =>
      isScrubbing &&
      _level == 0 &&
      (_target == Duration.zero || _target == _length);

  /// The direction of the press a click action refers to.
  RemoteScrubDirection? get lastPressDirection => _lastPressDirection;

  /// Changes the scrub's state for [event] and returns what the player does.
  ///
  /// The player calls it for every key event while the speed levels style
  /// applies.
  RemoteScrubAction handleKey(
    KeyEvent event, {
    required bool fromSeekbar,
    required bool controlsVisible,
    required bool skipButtonFocused,
  }) {
    final key = event.logicalKey;
    final direction = key == LogicalKeyboardKey.arrowRight
        ? RemoteScrubDirection.forward
        : key == LogicalKeyboardKey.arrowLeft
        ? RemoteScrubDirection.backward
        : null;

    if (direction != null) {
      if (event is KeyUpEvent) {
        if (_pressed != direction) {
          return isScrubbing
              ? RemoteScrubAction.consume
              : RemoteScrubAction.none;
        }
        _holdTimer?.cancel();
        _holdTimer = null;
        _stepTimer?.cancel();
        _stepTimer = null;
        final click = _pressIsClick;
        final hidden = _pressFromHidden;
        final stepped = _pressStepped;
        _pressed = null;
        _pressIsClick = false;
        _pressStepped = false;
        if (click) {
          _lastPressDirection = direction;
          return hidden
              ? RemoteScrubAction.clickFromHidden
              : RemoteScrubAction.clickOnSeekbar;
        }
        if (stepped && isScrubbing) {
          // Letting go after a hold step stops the scrub where it is and the
          // player treats the release as it does today.
          final oldLevel = _level;
          _level = 0;
          _clock?.cancel();
          _clock = null;
          if (oldLevel != 0) notifyListeners();
          return RemoteScrubAction.none;
        }
        return isScrubbing ? RemoteScrubAction.consume : RemoteScrubAction.none;
      }
      if (event is KeyRepeatEvent) {
        return _pressed == direction || isScrubbing
            ? RemoteScrubAction.consume
            : RemoteScrubAction.none;
      }
      if (!isScrubbing &&
          (skipButtonFocused || (controlsVisible && !fromSeekbar))) {
        return RemoteScrubAction.none;
      }
      if (isScrubbing) {
        _pressed = direction;
        _pressIsClick = false;
        _changeLevel(direction);
        _startSteps();
        return RemoteScrubAction.consume;
      }
      _pressed = direction;
      _pressIsClick = true;
      _pressFromHidden = !controlsVisible;
      _holdTimer?.cancel();
      _holdTimer = Timer(holdDelay, _startHold);
      return controlsVisible
          ? RemoteScrubAction.consume
          : RemoteScrubAction.revealControls;
    }

    if (!isScrubbing) return RemoteScrubAction.none;

    // While scrubbing, a repeat of any key the scrub owns is consumed, so the
    // player does not act on it.
    final RemoteScrubAction onDown;
    if (key.isSelectKey ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.space) {
      onDown = RemoteScrubAction.finishPlay;
    } else if (key == LogicalKeyboardKey.mediaPause) {
      onDown = RemoteScrubAction.finishPause;
    } else if (key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      onDown = RemoteScrubAction.consume;
    } else {
      // Back included: the player drops the scrub itself.
      return RemoteScrubAction.none;
    }
    if (event is KeyRepeatEvent) return RemoteScrubAction.consume;
    if (event is! KeyDownEvent) return RemoteScrubAction.none;
    if (key == LogicalKeyboardKey.mediaFastForward) {
      _changeLevel(RemoteScrubDirection.forward);
    } else if (key == LogicalKeyboardKey.mediaRewind) {
      _changeLevel(RemoteScrubDirection.backward);
    }
    return onDown;
  }

  /// Ends the scrub and any press in progress. Safe to call at any time.
  void stop() {
    _clock?.cancel();
    _clock = null;
    _holdTimer?.cancel();
    _holdTimer = null;
    _stepTimer?.cancel();
    _stepTimer = null;
    final was = isScrubbing;
    _direction = null;
    _level = 0;
    _pressed = null;
    _pressIsClick = false;
    _pressStepped = false;
    if (was) notifyListeners();
  }

  @override
  void dispose() {
    _clock?.cancel();
    _clock = null;
    _holdTimer?.cancel();
    _holdTimer = null;
    _stepTimer?.cancel();
    _stepTimer = null;
    _direction = null;
    _level = 0;
    _pressed = null;
    _pressIsClick = false;
    _pressStepped = false;
    super.dispose();
  }

  void _startHold() {
    _holdTimer = null;
    final pressed = _pressed;
    if (pressed == null) return;
    final length = duration();
    // With no length there is nothing to scrub, so the press stays a click.
    if (length <= Duration.zero) return;
    _pressIsClick = false;
    _direction = pressed;
    _level = 1;
    _length = length;
    _target = _clamp(position());
    _startClock();
    _startSteps();
    onMove(_target);
    notifyListeners();
  }

  /// Counts the key held down as one more press every [stepEvery].
  void _startSteps() {
    _pressStepped = false;
    _stepTimer?.cancel();
    _stepTimer = Timer.periodic(stepEvery, (_) {
      final pressed = _pressed;
      // A key held into the end changes nothing, so the badge does not flicker.
      if (pressed == null || _level == 0) return;
      _changeLevel(pressed);
      _pressStepped = true;
    });
  }

  void _changeLevel(RemoteScrubDirection to) {
    final oldDirection = _direction;
    final oldLevel = _level;
    if (_level == 0) {
      _direction = to;
      _level = 1;
      _startClock();
    } else if (to == _direction) {
      _level = min(_level + 1, speeds.length);
    } else if (_level > 1) {
      _level -= 1;
    } else {
      _direction = to;
      _level = 1;
    }
    if (_direction != oldDirection || _level != oldLevel) notifyListeners();
  }

  void _startClock() {
    _clock?.cancel();
    _lastTick = 0;
    _clock = Timer.periodic(tick, _onTick);
  }

  void _onTick(Timer timer) {
    final direction = _direction;
    if (direction == null || _level == 0) return;
    // A periodic timer's tick counts the periods that have passed, missed ones
    // included, so a late timer does not slow the scrub.
    final ticks = timer.tick - _lastTick;
    _lastTick = timer.tick;
    final step = tick * (ticks * speeds[_level - 1]);
    final forward = direction == RemoteScrubDirection.forward;
    _target = _clamp(forward ? _target + step : _target - step);
    onMove(_target);
    if (forward ? _target == _length : _target == Duration.zero) {
      // The scrub stays open at the end, waiting for a press or a finish key.
      _level = 0;
      _clock?.cancel();
      _clock = null;
      notifyListeners();
    }
  }

  Duration _clamp(Duration value) {
    if (value < Duration.zero) return Duration.zero;
    if (value > _length) return _length;
    return value;
  }
}
