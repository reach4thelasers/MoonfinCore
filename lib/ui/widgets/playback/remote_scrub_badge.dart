import 'package:flutter/material.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../playback/remote_scrub_controller.dart';

/// The speed of a remote scrub: an arrow icon, and the level when it is above
/// zero.
class RemoteScrubBadge extends StatelessWidget {
  const RemoteScrubBadge({
    super.key,
    required this.direction,
    required this.level,
    required this.atEnd,
  });

  /// The badge's height: the size of its icon.
  static const size = 28.0;

  final RemoteScrubDirection direction;

  /// 0 while the scrub waits: at the start or the end, or where the viewer let
  /// go of a press that sped it up.
  final int level;

  /// Whether a scrub at level 0 waits at the start or the end.
  final bool atEnd;

  @override
  Widget build(BuildContext context) {
    final forward = direction == RemoteScrubDirection.forward;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          level == 0
              // At an end the video may still be playing, so no pause icon. A
              // stop elsewhere outlives the release only when the video is held
              // paused.
              ? (atEnd
                    ? (forward ? Icons.last_page : Icons.first_page)
                    : Icons.pause)
              : (forward ? Icons.fast_forward : Icons.fast_rewind),
          size: size,
          color: Colors.white,
        ),
        if (level > 0) ...[
          const SizedBox(width: 4),
          Text(
            '$level',
            style: const TextStyle(
              color: Colors.white,
              fontSize: AppTypography.fontSizeSm,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}
