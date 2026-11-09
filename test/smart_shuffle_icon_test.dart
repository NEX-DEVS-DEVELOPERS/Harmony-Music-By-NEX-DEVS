import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonymusic/ui/widgets/smart_shuffle_button.dart';

void main() {
  testWidgets('smart shuffle icon shows shuffle + sparkle, on and off',
      (tester) async {
    for (final active in [true, false]) {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(body: SmartShuffleIcon(active: active, size: 24)),
      ));
      expect(find.byIcon(Icons.shuffle), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
      final sparkle = tester.widget<Icon>(find.byIcon(Icons.auto_awesome));
      expect(sparkle.color == Colors.amber, active);
    }
  });
}
