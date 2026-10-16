import 'dart:math';

import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../widgets/avatar_animal.dart';
import 'code_screen.dart';

class EditProfileScreen extends StatefulWidget {
  final bool premiereFois;
  const EditProfileScreen({super.key, this.premiereFois = false});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final nomController = TextEditingController();
  final prenomController = TextEditingController();
  final sexeController = TextEditingController();
  final dateController = TextEditingController();
  final telephoneController = TextEditingController();
  final emailController = TextEditingController();
  String code = '';
  String avatarChoisi = '';

  bool erreurNom = false;
  bool erreurPrenom = false;
  bool erreurSexe = false;
  bool erreurDate = false;

  @override
  void initState() {
    super.initState();
    if (widget.premiereFois) {
      // À l'inscription, on propose déjà un avatar au hasard : l'utilisateur
      // peut en choisir un autre d'un simple appui.
      avatarChoisi = avatarsAnimaux[Random().nextInt(avatarsAnimaux.length)].id;
    } else {
      chargerProfil();
    }
  }

  @override
  void dispose() {
    nomController.dispose();
    prenomController.dispose();
    sexeController.dispose();
    dateController.dispose();
    telephoneController.dispose();
    emailController.dispose();
    super.dispose();
  }

  Future<void> chargerProfil() async {
    try {
      final profile = await SupabaseService().loadProfile();
      if (!mounted) return;
      if (profile != null) {
        setState(() {
          nomController.text = profile['nom'] as String? ?? '';
          prenomController.text = profile['prenom'] as String? ?? '';
          sexeController.text = profile['sexe'] as String? ?? '';
          dateController.text = profile['date'] as String? ?? '';
          telephoneController.text = profile['telephone'] as String? ?? '';
          emailController.text = profile['email'] as String? ?? '';
          code = profile['code'] as String? ?? '';
          avatarChoisi = profile['avatar'] as String? ?? '';
        });
      }
    } catch (e) {
      debugPrint('[KinFlow] Erreur chargement profil: $e');
    }
  }

  /// Une pastille d'animal rond dans le sélecteur ; un anneau bleu marque
  /// l'avatar actuellement choisi.
  Widget _choixAnimal(AvatarAnimal animal) {
    final selectionne = animal.id == avatarChoisi;
    return Tooltip(
      message: animal.nom,
      child: InkWell(
        key: ValueKey('avatar_${animal.id}'),
        customBorder: const CircleBorder(),
        onTap: () {
          setState(() {
            avatarChoisi = animal.id;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: animal.couleur,
            border: Border.all(
              color: selectionne
                  ? const Color(0xFF1565C0) // KinColors.bleu
                  : Colors.transparent,
              width: 3,
            ),
          ),
          child: Center(
            child: Text(
              animal.emoji,
              style: const TextStyle(fontSize: 26),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.premiereFois ? "Inscription" : "Modifier mon profil",
        ),
        centerTitle: true,
        automaticallyImplyLeading: !widget.premiereFois,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              AvatarAnimalWidget(taille: 90, avatarId: avatarChoisi),

              const SizedBox(height: 12),

              Text(
                widget.premiereFois
                    ? "Choisis ton avatar (animal)"
                    : "Ton avatar",
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),

              const SizedBox(height: 10),

              // Les 10 animaux ronds façon Xender : un appui = choix.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final animal in avatarsAnimaux) _choixAnimal(animal),
                ],
              ),

              const SizedBox(height: 30),

              Text(
                widget.premiereFois
                    ? "Renseignez vos informations"
                    : "Modifier mes informations",
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 20),

              if (code.isNotEmpty) ...[
                TextFormField(
                  initialValue: code.length == 8
                      ? '${code.substring(0, 4)}-${code.substring(4)}'
                      : code,
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: "Code de compte (privé)",
                    border: OutlineInputBorder(),
                    helperText: "Sert à te reconnecter : ne le partage pas",
                  ),
                ),
                const SizedBox(height: 15),
              ],

              TextField(
                controller: nomController,
                onChanged: (value) {
                  if (value.isNotEmpty) {
                    setState(() {
                      erreurNom = false;
                    });
                  }
                },
                decoration: InputDecoration(
                  labelText: "Nom",
                  border: const OutlineInputBorder(),
                  errorText: erreurNom ? "Le nom est obligatoire" : null,
                ),
              ),

              const SizedBox(height: 15),

              TextField(
                controller: prenomController,
                onChanged: (value) {
                  if (value.isNotEmpty) {
                    setState(() {
                      erreurPrenom = false;
                    });
                  }
                },
                decoration: InputDecoration(
                  labelText: "Prénom",
                  border: const OutlineInputBorder(),
                  errorText: erreurPrenom ? "Le prénom est obligatoire" : null,
                ),
              ),

              const SizedBox(height: 15),

              DropdownButtonFormField<String>(
                initialValue: sexeController.text.isEmpty
                    ? null
                    : sexeController.text,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                decoration: InputDecoration(
                  labelText: "Sexe",
                  border: const OutlineInputBorder(),
                  errorText: erreurSexe ? "Choisissez le sexe" : null,
                ),
                items: const [
                  DropdownMenuItem(value: "M", child: Text("Masculin")),
                  DropdownMenuItem(value: "F", child: Text("Féminin")),
                ],
                onChanged: (value) {
                  sexeController.text = value!;
                  setState(() {
                    erreurSexe = false;
                  });
                },
              ),

              const SizedBox(height: 15),

              TextField(
                controller: dateController,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: "Date de naissance",
                  border: const OutlineInputBorder(),
                  suffixIcon: const Icon(Icons.calendar_today),
                  errorText: erreurDate
                      ? "Choisissez votre date de naissance"
                      : null,
                ),
                onTap: () async {
                  DateTime? date = await showDatePicker(
                    context: context,
                    initialDate: DateTime(2000),
                    firstDate: DateTime(1900),
                    lastDate: DateTime.now(),
                  );
                  if (date != null) {
                    dateController.text =
                        "${date.day}/${date.month}/${date.year}";
                    setState(() {
                      erreurDate = false;
                    });
                  }
                },
              ),

              const SizedBox(height: 15),

              TextField(
                controller: telephoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: "Numéro de téléphone",
                  border: OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 15),

              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: "E-mail",
                  border: OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 25),

              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                ),
                onPressed: () async {
                  setState(() {
                    erreurNom = nomController.text.isEmpty;
                    erreurPrenom = prenomController.text.isEmpty;
                    erreurSexe = sexeController.text.isEmpty;
                    erreurDate = dateController.text.isEmpty;
                  });

                  if (erreurNom || erreurPrenom || erreurSexe || erreurDate) {
                    return;
                  }

                  final ok = await SupabaseService().saveProfile(
                    nom: nomController.text,
                    prenom: prenomController.text,
                    sexe: sexeController.text,
                    date: dateController.text,
                    telephone: telephoneController.text,
                    email: emailController.text,
                    avatar: avatarChoisi,
                  );

                  if (!context.mounted) return;

                  if (!ok) {
                    final detail =
                        SupabaseService().derniereErreur ?? "Réessayez.";
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          "Erreur lors de l'enregistrement. $detail",
                        ),
                      ),
                    );
                    return;
                  }

                  if (widget.premiereFois) {
                    final code = await SupabaseService().enregistrerAvecCode(
                      nom: nomController.text,
                      prenom: prenomController.text,
                      sexe: sexeController.text,
                      date: dateController.text,
                      telephone: telephoneController.text,
                      email: emailController.text,
                      avatar: avatarChoisi,
                    );

                    if (!context.mounted) return;

                    if (code == null) {
                      final detail =
                          SupabaseService().derniereErreur ?? "Réessayez.";
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            "Erreur lors de l'enregistrement. $detail",
                          ),
                        ),
                      );
                      return;
                    }

                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (context) => CodeScreen(code: code),
                      ),
                    );
                  } else {
                    Navigator.pop(context);
                  }
                },
                child: const Text("Enregistrer"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
