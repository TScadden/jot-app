import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/splash/splash_screen.dart';

void main() {
  runApp(const TabsLabApp());
}

class TabsLabApp extends StatelessWidget {
  const TabsLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Tabs Lab',
      debugShowCheckedModeBanner: false,
      home: SplashScreen(),
    );
  }
}
