import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'bindings/app_bindings.dart';
import 'home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BanglaTranscribeApp());
}

class BanglaTranscribeApp extends StatelessWidget {
  const BanglaTranscribeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Bangla Transcribe',
      debugShowCheckedModeBanner: false,
      initialBinding: AppBindings(),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A1A1A),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
