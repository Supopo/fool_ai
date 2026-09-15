import 'package:flutter_test/flutter_test.dart';

import 'package:fool_ai/main.dart';

void main() {
  testWidgets('app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('ChatGPT'), findsWidgets);
    expect(find.text('DeepSeek'), findsWidgets);
    expect(find.text('豆包'), findsWidgets);
    expect(find.textContaining('对比'), findsWidgets);
  });
}
