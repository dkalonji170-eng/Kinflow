import 'package:flutter/material.dart';
import 'report_problem_screen.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Aide / Contact"), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Icon(Icons.help_outline, size: 80),
          const SizedBox(height: 20),
          const Text(
            "Besoin d'aide ?",
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 15),
          const Text(
            "Contactez-nous pour toute question "
            "ou pour signaler un problème.",
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 30),
          const ListTile(
            leading: Icon(Icons.email),
            title: Text("Email"),
            subtitle: Text("contact@kinflow.com"),
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.phone),
            title: Text("Téléphone"),
            subtitle: Text("+243 972278340"),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.report_problem),
            title: const Text("Signaler un problème"),
            trailing: const Icon(Icons.arrow_forward_ios),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ReportProblemScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
