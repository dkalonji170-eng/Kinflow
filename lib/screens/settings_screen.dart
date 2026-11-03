import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'notifications_screen.dart';
import '../theme/theme_provider.dart';
import 'about_screen.dart';
import 'help_screen.dart';
import '../services/diagnostics_service.dart';
import 'voix_guidage_screen.dart';

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
            leading: const Icon(Icons.record_voice_over),
            title: const Text("Guidage vocal"),
            trailing: const Icon(Icons.arrow_forward_ios),
            onTap: () {
              Journal.i('ECRAN', 'Ouverture du guidage vocal');
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const VoixGuidageScreen(),
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
        ],
      ),
    );
  }
}
