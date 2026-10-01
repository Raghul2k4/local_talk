import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Big push-to-talk control.
///
/// - Hold to talk, release to stop.
/// - A quick tap (< 300 ms) locks talk mode so users don't have to keep their
///   finger down forever; tap again to unlock.
class PttButton extends StatefulWidget {
  final bool isEnabled;
  final bool isTalking;
  final double level;

  /// Optional live level source. When supplied it drives the ring directly, so
  /// the ~20 updates per second never rebuild the enclosing screen. Falls back
  /// to [level] when null.
  final ValueListenable<double>? levelNotifier;

  final Future<void> Function() onStart;
  final Future<void> Function() onStop;

  const PttButton({
    super.key,
    required this.isEnabled,
    required this.isTalking,
    required this.level,
    this.levelNotifier,
    required this.onStart,
    required this.onStop,
  });

  @override
  State<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends State<PttButton> {
  bool _pressed = false;
  bool _locked = false;
  DateTime? _pressStart;
  Timer? _lockArmedTimer;
  bool _waitingForStart = false;

  /// When the caller passes a [ValueNotifier] it is used directly so live
  /// level updates never rebuild the parent widget. Otherwise we mirror the
  /// plain [PttButton.level] double.
  late final ValueNotifier<double> _fallbackLevel =
      ValueNotifier<double>(widget.level);
  ValueListenable<double>? _levelNotifier;

  ValueListenable<double> get _levelSource => _levelNotifier ?? _fallbackLevel;

  @override
  void initState() {
    super.initState();
    _levelNotifier = widget.levelNotifier;
  }

  @override
  void didUpdateWidget(PttButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.levelNotifier != _levelNotifier) {
      _levelNotifier = widget.levelNotifier;
    }
    if (_levelNotifier == null && oldWidget.level != widget.level) {
      _fallbackLevel.value = widget.level;
    }
  }

  @override
  void dispose() {
    _lockArmedTimer?.cancel();
    _fallbackLevel.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!widget.isEnabled || _waitingForStart) return;
    setState(() => _waitingForStart = true);
    HapticFeedback.mediumImpact();
    await widget.onStart();
    if (!mounted) return;
    setState(() => _waitingForStart = false);
    if (!widget.isTalking) {
      // Start failed (e.g. mic permission denied) - give error haptic.
      HapticFeedback.heavyImpact();
    }
  }

  Future<void> _stop() async {
    _locked = false;
    if (widget.isTalking) {
      HapticFeedback.selectionClick();
      await widget.onStop();
    }
  }

  void _handleTapDown(TapDownDetails _) {
    if (!widget.isEnabled || widget.isTalking) {
      if (widget.isTalking && _locked) {
        // Tap while locked: unlock and stop.
        _handleTapStop();
      }
      return;
    }
    setState(() => _pressed = true);
    _pressStart = DateTime.now();
    _start();
  }

  void _handleTapUp(TapUpDetails _) {
    if (!_pressed) return;
    setState(() => _pressed = false);
    final held = _pressStart == null
        ? const Duration(milliseconds: 400)
        : DateTime.now().difference(_pressStart!);
    _pressStart = null;

    if (!widget.isTalking) {
      // Mic never actually started - nothing to do.
      return;
    }

    if (held < const Duration(milliseconds: 300)) {
      // Quick tap: lock talk mode.
      _locked = true;
      HapticFeedback.selectionClick();
    } else {
      _stop();
    }
  }

  void _handleTapCancel() {
    if (!_pressed) return;
    setState(() => _pressed = false);
    _pressStart = null;
    if (widget.isTalking && !_locked) _stop();
  }

  void _handleTapStop() {
    setState(() {});
    _stop();
  }

  @override
  Widget build(BuildContext context) {
    final talking = widget.isTalking;
    // Clamped here rather than in the painter so the notifier's raw value can
    // be fed straight in.
    final level = talking ? widget.level.clamp(0.0, 1.0) : 0.0;
    _fallbackLevel.value = level;
    const size = 190.0;
    final Color face;
    final IconData icon;
    final String label;
    if (!widget.isEnabled) {
      face = AppTheme.surfaceHigh;
      icon = Icons.mic_off_outlined;
      label = 'NOT CONNECTED';
    } else if (talking) {
      face = AppTheme.danger;
      icon = Icons.graphic_eq;
      label = _locked ? 'ON AIR · TAP TO STOP' : 'ON AIR';
    } else {
      face = AppTheme.primaryDim;
      icon = Icons.mic_none;
      label = 'HOLD TO TALK';
    }

    return Semantics(
      button: true,
      enabled: widget.isEnabled,
      label: talking ? 'Stop talking' : 'Push to talk',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 90),
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: size,
                  height: size,
                  // The level ring repaints on its own, ~20x per second,
                  // instead of dragging the whole screen down with it.
                  child: ValueListenableBuilder<double>(
                    valueListenable: _levelSource,
                    builder: (context, level, _) => CustomPaint(
                      painter: _LevelRingPainter(
                        level: talking ? level.clamp(0.0, 1.0) : 0.0,
                        color: talking ? AppTheme.danger : AppTheme.primary,
                      ),
                    ),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: size - 34,
                  height: size - 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: face,
                    boxShadow: [
                      BoxShadow(
                        color: (talking ? AppTheme.danger : AppTheme.primary)
                            .withValues(alpha: talking ? 0.45 : 0.18),
                        blurRadius: talking ? 30 : 18,
                        spreadRadius: talking ? 6 : 2,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icon,
                        size: 56,
                        color: widget.isEnabled
                            ? Colors.white
                            : AppTheme.textSecondary,
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          label,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 10,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LevelRingPainter extends CustomPainter {
  final double level;
  final Color color;

  _LevelRingPainter({required this.level, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;

    final track = Paint()
      ..color = AppTheme.outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    canvas.drawCircle(center, radius, track);

    if (level > 0.01) {
      final arc = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        math.pi * 2 * level,
        false,
        arc,
      );
    }
  }

  @override
  bool shouldRepaint(_LevelRingPainter oldDelegate) =>
      oldDelegate.level != level || oldDelegate.color != color;
}
