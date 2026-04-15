import 'package:flutter_test/flutter_test.dart';
import 'package:yanfarkle_flutter/main.dart';
import 'package:yanfarkle_flutter/game.dart';
import 'package:yanfarkle_flutter/network_manager.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('App loads smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => Game()),
          ChangeNotifierProvider.value(value: NetworkManager.shared),
        ],
        child: const YanFarkleApp(),
      ),
    );

    // Give it time to build
    await tester.pumpAndSettle();

    // Just verify the app successfully loaded without throwing exceptions
    expect(find.byType(YanFarkleApp), findsOneWidget);
  });
}
