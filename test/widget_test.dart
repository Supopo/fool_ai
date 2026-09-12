import 'package:flutter_test/flutter_test.dart';

import 'package:fool_ai/main.dart';

void main() {
  testWidgets('app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('ChatGPT'), findsOneWidget);
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('豆包'), findsOneWidget);
    expect(find.text('通义千问'), findsOneWidget);
    expect(find.text('文心一言'), findsOneWidget);

  });
}
