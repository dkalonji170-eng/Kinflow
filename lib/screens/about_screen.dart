import 'package:flutter/material.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("À propos"), centerTitle: true),

      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 20),
            Image.asset(
              Theme.of(context).brightness == Brightness.dark
                  ? "assets/kinflow_dark.jpg"
                  : "assets/kinflow.jpg",
              height: 90,
            ),
            const SizedBox(height: 20),
            const ListTile(
              leading: Icon(Icons.info),
              title: Text("Version"),
              subtitle: Text("1.0.0"),
            ),
            const Divider(),
            const ListTile(
              leading: Icon(Icons.code),
              title: Text("Développeur"),
              subtitle: Text("Mareza Kalonji Daniel"),
            ),
            const Divider(),
            const ListTile(
              leading: Icon(Icons.copyright),
              title: Text("© 2026 KinFlow"),
            ),
          ],
        ),
      ),
    );
  }
}
