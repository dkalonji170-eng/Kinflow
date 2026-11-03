import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  bool notifications = true;
  bool embouteillages = true;
  bool routesBloquees = true;
  bool publicationsPages = true;
  bool reponsesCommentaires = true;

  @override
  void initState() {
    super.initState();
    chargerPreferences();
  }

  Future<void> chargerPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      notifications = prefs.getBool("notif_activées") ?? true;
      embouteillages = prefs.getBool("notif_embouteillages") ?? true;
      routesBloquees = prefs.getBool("notif_routes_bloquees") ?? true;
      publicationsPages = prefs.getBool("notif_publications_pages") ?? true;
      reponsesCommentaires =
          prefs.getBool("notif_reponses_commentaires") ?? true;
    });
  }

  Future<void> sauvegarderPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool("notif_activées", notifications);
    await prefs.setBool("notif_embouteillages", embouteillages);
    await prefs.setBool("notif_routes_bloquees", routesBloquees);
    await prefs.setBool("notif_publications_pages", publicationsPages);
    await prefs.setBool(
      "notif_reponses_commentaires",
      reponsesCommentaires,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text("Notifications"), centerTitle: true),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text("Activer les notifications"),
            value: notifications,
            thumbColor: WidgetStateProperty.resolveWith<Color>((states) {
              if (states.contains(WidgetState.selected)) {
                return colorScheme.onPrimary;
              }
              return colorScheme.onSurfaceVariant;
            }),
            trackColor: WidgetStateProperty.resolveWith<Color>((states) {
              if (states.contains(WidgetState.selected)) {
                return colorScheme.primary;
              }
              return colorScheme.surfaceContainerHighest;
            }),
            onChanged: (value) {
              setState(() {
                notifications = value;
                if (!notifications) {
                  embouteillages = false;
                  routesBloquees = false;
                }
              });
              sauvegarderPreferences();
            },
          ),
          const Divider(),
          SwitchListTile(
            title: const Text("Publications des pages suivies"),
            value: publicationsPages,
            onChanged: notifications
                ? (value) {
                    setState(() => publicationsPages = value);
                    sauvegarderPreferences();
                  }
                : null,
          ),
          const Divider(),
          SwitchListTile(
            title: const Text("Réponses à mes commentaires"),
            value: reponsesCommentaires,
            onChanged: notifications
                ? (value) {
                    setState(() => reponsesCommentaires = value);
                    sauvegarderPreferences();
                  }
                : null,
          ),
          SwitchListTile(
            title: const Text("Alertes embouteillages"),
            value: embouteillages,
            thumbColor: WidgetStateProperty.resolveWith<Color>((states) {
              if (states.contains(WidgetState.selected)) {
                return colorScheme.onPrimary;
              }
              return colorScheme.onSurfaceVariant;
            }),
            trackColor: WidgetStateProperty.resolveWith<Color>((states) {
              if (states.contains(WidgetState.selected)) {
                return colorScheme.primary;
              }
              return colorScheme.surfaceContainerHighest;
            }),
            onChanged: notifications
                ? (value) {
                    setState(() {
                      embouteillages = value;
                    });
                    sauvegarderPreferences();
                  }
                : null,
          ),
          const Divider(),
          SwitchListTile(
            title: const Text("Alertes routes bloquées"),
            value: routesBloquees,
            thumbColor: WidgetStateProperty.resolveWith<Color>((states) {
              if (states.contains(WidgetState.selected)) {
                return colorScheme.onPrimary;
              }
              return colorScheme.onSurfaceVariant;
            }),
            trackColor: WidgetStateProperty.resolveWith<Color>((states) {
              if (states.contains(WidgetState.selected)) {
                return colorScheme.primary;
              }
              return colorScheme.surfaceContainerHighest;
            }),
            onChanged: notifications
                ? (value) {
                    setState(() {
                      routesBloquees = value;
                    });
                    sauvegarderPreferences();
                  }
                : null,
          ),
        ],
      ),
    );
  }
}
