import 'package:flutter/material.dart';

void main() {
  runApp(const OpenMettleApp());
}

class OpenMettleApp extends StatelessWidget {
  const OpenMettleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'OpenMettle',
      home: Scaffold(body: Center(child: Text('OpenMettle'))),
    );
  }
}
