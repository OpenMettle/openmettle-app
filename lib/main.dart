import 'package:flutter/widgets.dart';

void main() {
  runApp(const OpenMettleApp());
}

class OpenMettleApp extends StatelessWidget {
  const OpenMettleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      title: 'OpenMettle',
      color: const Color(0xFF222222),
      builder: (context, child) => const Center(child: Text('OpenMettle')),
    );
  }
}
