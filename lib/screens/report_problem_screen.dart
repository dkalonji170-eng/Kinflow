import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/diagnostics_service.dart';

class ReportProblemScreen extends StatefulWidget {
  const ReportProblemScreen({super.key});

  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  String? problemeChoisi;

  final TextEditingController descriptionController = TextEditingController();

  bool autorise = true;
  bool erreur = false;

  final List<String> problemes = [
    "Accident",
    "Travaux sur la route",
    "Route endommagée",
    "Inondation",
    "Barrage / contrôle",
    "Obstacle sur la route",
    "Autre",
  ];

  @override
  void initState() {
    super.initState();
    verifierDernierSignalement();
  }

  @override
  void dispose() {
    descriptionController.dispose();
    super.dispose();
  }

  Future<void> verifierDernierSignalement() async {
    final prefs = await SharedPreferences.getInstance();
    final heure = prefs.getInt("heure_probleme");

    if (!mounted) return;

    if (heure != null) {
      final maintenant = DateTime.now().millisecondsSinceEpoch;
      final difference = maintenant - heure;

      if (difference < 15 * 60 * 1000) {
        setState(() {
          autorise = false;
        });
      }
    }
  }

  Future<void> envoyerSignalement() async {
    if (problemeChoisi == null || descriptionController.text.trim().isEmpty) {
      setState(() {
        erreur = true;
      });
      return;
    }

    Journal.i('PROBLEME', 'Signalement de problème enregistré localement', {
      'type': problemeChoisi,
      'description': descriptionController.text.trim(),
    });

    final prefs = await SharedPreferences.getInstance();

    await prefs.setInt("heure_probleme", DateTime.now().millisecondsSinceEpoch);

    if (!mounted) return;

    setState(() {
      autorise = false;
      erreur = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Signalement envoyé avec succès")),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Signaler un problème"),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: "Type de problème",
                  border: OutlineInputBorder(),
                ),
                items: problemes.map((p) {
                  return DropdownMenuItem(value: p, child: Text(p));
                }).toList(),
                onChanged: autorise
                    ? (value) {
                        setState(() {
                          problemeChoisi = value;
                          erreur = false;
                        });
                      }
                    : null,
              ),

              const SizedBox(height: 20),

              TextField(
                controller: descriptionController,
                maxLines: 4,
                enabled: autorise,
                onChanged: (value) {
                  setState(() {
                    erreur = false;
                  });
                },
                decoration: const InputDecoration(
                  hintText: "Décrivez le problème...",
                  border: OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 20),

              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                ),
                onPressed: autorise ? envoyerSignalement : null,
                child: const Text("Envoyer"),
              ),

              if (erreur)
                Padding(
                  padding: const EdgeInsets.only(top: 15),
                  child: Text(
                    "Veuillez remplir les informations avant d'envoyer.",
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

              if (!autorise)
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Text(
                    "Vous avez déjà envoyé un signalement.\nRéessayez dans quelques minutes.",
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
