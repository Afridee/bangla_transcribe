import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'package:bangla_transcribe/bindings/app_bindings.dart';
import 'package:bangla_transcribe/home_page.dart';

void main() {
  testWidgets('Home shows Bangla title', (tester) async {
    AppBindings().dependencies();
    await tester.pumpWidget(
      GetMaterialApp(home: const HomePage()),
    );
    expect(find.text('বাংলা'), findsOneWidget);
    Get.reset();
  });
}
