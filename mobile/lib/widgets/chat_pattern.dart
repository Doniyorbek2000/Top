import 'dart:math';

import 'package:flutter/material.dart';

/// Faint doodle pattern behind messages (Telegram-style), drawn from Material icon glyphs.
/// The layout is deterministic so it does not shimmer between rebuilds.
class ChatPatternPainter extends CustomPainter {
  ChatPatternPainter({required this.color});

  final Color color;

  static const _icons = <IconData>[
    Icons.chat_bubble_outline_rounded,
    Icons.favorite_border_rounded,
    Icons.star_border_rounded,
    Icons.music_note_rounded,
    Icons.photo_camera_outlined,
    Icons.emoji_emotions_outlined,
    Icons.mic_none_rounded,
    Icons.cake_outlined,
    Icons.local_cafe_outlined,
    Icons.flight_rounded,
    Icons.pets_rounded,
    Icons.wb_sunny_outlined,
    Icons.headphones_rounded,
    Icons.sports_esports_outlined,
    Icons.local_florist_outlined,
    Icons.celebration_outlined,
    Icons.send_rounded,
    Icons.nightlight_outlined,
  ];

  static const _cell = 64.0;

  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(7);
    final columns = (size.width / _cell).ceil() + 1;
    final rows = (size.height / _cell).ceil() + 1;
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        final icon = _icons[random.nextInt(_icons.length)];
        final iconSize = 20.0 + random.nextDouble() * 8;
        // Offset every other row by half a cell and jitter each glyph a little.
        final dx = column * _cell + (row.isOdd ? _cell / 2 : 0) + (random.nextDouble() - 0.5) * 14;
        final dy = row * _cell + (random.nextDouble() - 0.5) * 14;
        final angle = (random.nextDouble() - 0.5) * 0.9;
        final painter = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(icon.codePoint),
            style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: iconSize, color: color),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        canvas
          ..save()
          ..translate(dx, dy)
          ..rotate(angle);
        painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(ChatPatternPainter oldDelegate) => oldDelegate.color != color;
}
