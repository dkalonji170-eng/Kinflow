import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/diagnostics_service.dart';
import '../services/supabase_service.dart';

class ReportProblemScreen extends StatefulWidget {
  const ReportProblemScreen({super.key});

  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen>
    with SingleTickerProviderStateMixin {
  String? problemeChoisi;

  final TextEditingController descriptionController = TextEditingController();

  bool autorise = true;
  bool erreur = false;
  bool _envoiEnCours = false;

  final List<String> problemes = [
    "Accident",
    "Travaux sur la route",
    "Route endommagée",
    "Inondation",
    "Barrage / contrôle",
    "Obstacle sur la route",
    "Autre",
  ];

  late final TabController _tabController;
  List<Map<String, dynamic>> _signalements = [];
  bool _chargementListe = true;
  final Set<String> _likesEnCours = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    verifierDernierSignalement();
    _chargerSignalements();
  }

  @override
  void dispose() {
    descriptionController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _chargerSignalements() async {
    final liste = await SupabaseService().listeSignalementsProblemes();
    if (!mounted) return;
    setState(() {
      _signalements = liste;
      _chargementListe = false;
    });
  }

  Future<void> _toggleLike(Map<String, dynamic> s) async {
    final id = s['id']?.toString();
    if (id == null || _likesEnCours.contains(id)) return;
    setState(() => _likesEnCours.add(id));
    final res = await SupabaseService().toggleLikeProbleme(id);
    if (!mounted) return;
    setState(() {
      _likesEnCours.remove(id);
      if (res != null) {
        final idx = _signalements.indexWhere((e) => e['id'] == id);
        if (idx != -1) {
          _signalements[idx] = {
            ..._signalements[idx],
            'j_ai_like': res['aime'] == true,
            'nb_likes': res['nb'] ?? _signalements[idx]['nb_likes'],
          };
          _signalements.sort((a, b) {
            final na = (a['nb_likes'] as num?)?.toInt() ?? 0;
            final nb = (b['nb_likes'] as num?)?.toInt() ?? 0;
            if (na != nb) return nb.compareTo(na);
            final da = DateTime.tryParse(a['cree_a']?.toString() ?? '') ?? DateTime(0);
            final db = DateTime.tryParse(b['cree_a']?.toString() ?? '') ?? DateTime(0);
            return db.compareTo(da);
          });
        }
      }
    });
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

    setState(() => _envoiEnCours = true);
    final ok = await SupabaseService().signalerProbleme(
      problemeChoisi!,
      descriptionController.text.trim(),
    );
    if (!mounted) return;
    setState(() => _envoiEnCours = false);

    if (ok == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Envoi impossible. Vérifie ta connexion.")),
      );
      return;
    }

    Journal.i('PROBLEME', 'Signalement de problème envoyé', {
      'type': problemeChoisi,
      'description': descriptionController.text.trim(),
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt("heure_probleme", DateTime.now().millisecondsSinceEpoch);

    if (!mounted) return;

    setState(() {
      autorise = false;
      erreur = false;
      descriptionController.clear();
      problemeChoisi = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Signalement envoyé avec succès")),
    );
    _chargerSignalements();
  }

  String _tempsRelatif(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inMinutes < 1) return 'à l\'instant';
    if (diff.inMinutes < 60) return 'il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'il y a ${diff.inHours} h';
    if (diff.inDays < 7) return 'il y a ${diff.inDays} j';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  Widget _ongletSignaler() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              value: problemeChoisi,
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
              onPressed: (autorise && !_envoiEnCours) ? envoyerSignalement : null,
              child: _envoiEnCours
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text("Envoyer"),
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
    );
  }

  Widget _ongletListe() {
    if (_chargementListe) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_signalements.isEmpty) {
      return const Center(child: Text("Aucun signalement pour l'instant"));
    }
    return RefreshIndicator(
      onRefresh: _chargerSignalements,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _signalements.length,
        itemBuilder: (context, index) {
          final s = _signalements[index];
          final id = s['id']?.toString() ?? '';
          final nbLikes = (s['nb_likes'] as num?)?.toInt() ?? 0;
          final jAiLike = s['j_ai_like'] == true;
          final enCours = _likesEnCours.contains(id);
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          s['type']?.toString() ?? '',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _tempsRelatif(s['cree_a']?.toString()),
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    s['description']?.toString() ?? '',
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      InkWell(
                        onTap: enCours ? null : () => _toggleLike(s),
                        borderRadius: BorderRadius.circular(20),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                jAiLike ? Icons.thumb_up : Icons.thumb_up_outlined,
                                size: 18,
                                color: jAiLike
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '$nbLikes',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: jAiLike
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Signaler un problème"),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: "Signaler"),
            Tab(text: "Signalements"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _ongletSignaler(),
          _ongletListe(),
        ],
      ),
    );
  }
}
