import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'notifications_screen.dart';
import 'offline_maps_screen.dart';
import '../theme_provider.dart';
import 'about_screen.dart';
import 'help_screen.dart';
import 'splash_screen.dart';
import '../services/diagnostics_service.dart';
import '../services/supabase_service.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Scaffold(
      appBar: AppBar(title: const Text("Paramètres"), centerTitle: true),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.notifications),
            title: const Text("Notifications"),
            trailing: const Icon(Icons.arrow_forward_ios),
            onTap: () {
              Journal.i('ECRAN', 'Ouverture des notifications');
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const NotificationsScreen(),
                ),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.offline_pin),
            title: const Text("Cartes hors ligne"),
            trailing: const Icon(Icons.arrow_forward_ios),
            onTap: () {
              Journal.i('ECRAN', 'Ouverture des cartes hors ligne');
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const OfflineMapsScreen(),
                ),
              );
            },
          ),
          const Divider(),
          ExpansionTile(
            leading: Icon(
              themeProvider.modeSombre ? Icons.dark_mode : Icons.light_mode,
            ),
            title: const Text("Mode"),
            children: [
              ListTile(
                leading: const Icon(Icons.light_mode),
                title: const Text("Mode clair"),
                onTap: () {
                  Provider.of<ThemeProvider>(
                    context,
                    listen: false,
                  ).changerMode(false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.dark_mode),
                title: const Text("Mode sombre"),
                onTap: () {
                  Provider.of<ThemeProvider>(
                    context,
                    listen: false,
                  ).changerMode(true);
                },
              ),
            ],
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info),
            title: const Text("À propos de KinFlow"),
            trailing: const Icon(Icons.arrow_forward_ios),
            onTap: () {
              Journal.i('ECRAN', 'Ouverture de « À propos »');
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AboutScreen()),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.phone),
            title: const Text("Aide / Contact"),
            trailing: const Icon(Icons.arrow_forward_ios),
            onTap: () {
              Journal.i('ECRAN', 'Ouverture de l\'aide / contact');
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const HelpScreen()),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text("Déconnexion"),
            trailing: const Icon(Icons.arrow_forward_ios),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) {
                  final onSurface = Theme.of(context).colorScheme.onSurface;
                  return AlertDialog(
                    title: Text(
                      "Déconnexion",
                      style: TextStyle(color: onSurface),
                    ),
                    content: Text(
                      "Voulez-vous vraiment vous déconnecter ?",
                      style: TextStyle(color: onSurface),
                    ),
                    actions: [
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: onSurface),
                        onPressed: () {
                          Navigator.pop(context);
                        },
                        child: const Text("Annuler"),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: onSurface),
                        onPressed: () async {
                          final navigator = Navigator.of(context);
                          Journal.i('COMPTE', 'Déconnexion confirmée');
                          await SupabaseService().signOut();
                          navigator.pop();
                          navigator.pushAndRemoveUntil(
                            MaterialPageRoute(
                              builder: (context) => const SplashScreen(),
                            ),
                            (route) => false,
                          );
                        },
                        child: const Text("Déconnexion"),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}
