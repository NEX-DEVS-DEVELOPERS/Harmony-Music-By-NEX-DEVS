import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../player/player_controller.dart';

/// Shuffle icon with a sparkle badge: the "smart shuffle" symbol.
class SmartShuffleIcon extends StatelessWidget {
  const SmartShuffleIcon({super.key, required this.active, this.size = 24});
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.titleLarge!.color!;
    final color = active ? base : base.withValues(alpha: 0.35);
    return SizedBox(
      width: size + 6,
      height: size + 4,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomLeft,
        children: [
          Icon(Icons.shuffle, size: size, color: color),
          Positioned(
            right: 0,
            top: 0,
            child: Icon(Icons.auto_awesome,
                size: size * 0.5,
                color: active ? Colors.amber : color),
          ),
        ],
      ),
    );
  }
}

/// The shuffle button used on the play bars: smart-shuffle icon, an optional
/// small text label and a tooltip saying what it does and whether it is on.
class SmartShuffleButton extends StatelessWidget {
  const SmartShuffleButton(
      {super.key,
      required this.controller,
      this.iconSize = 22,
      this.showLabel = true});
  final PlayerController controller;
  final double iconSize;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final on = controller.isShuffleModeEnabled.value;
      final base = Theme.of(context).textTheme.titleLarge!.color!;
      return Tooltip(
        message: on
            ? 'Smart shuffle is on - random order, no repeats until every song '
                'has played, same artist spread apart (tap to turn off)'
            : 'Smart shuffle is off (tap to turn on)',
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: controller.toggleShuffleMode,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SmartShuffleIcon(active: on, size: iconSize),
                if (showLabel)
                  Text(
                    on ? 'Smart shuffle' : 'Shuffle',
                    maxLines: 1,
                    style: TextStyle(
                        fontSize: 8.5,
                        height: 1.1,
                        fontWeight: on ? FontWeight.bold : FontWeight.normal,
                        color: on ? Colors.amber : base.withValues(alpha: 0.35)),
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }
}
