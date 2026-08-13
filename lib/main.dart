import 'package:flutter/material.dart';

import 'ui/home_screen.dart';
import 'ui/theme.dart';

void main() {
  runApp(const StructuraApp());
}

class StructuraApp extends StatelessWidget {
  const StructuraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Structura',
      debugShowCheckedModeBanner: false,
      theme: structuraTheme,
      home: const HomeScreen(),
    );
  }
}
