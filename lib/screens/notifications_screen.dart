import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/supabase_service.dart';

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
  bool messages = true;
  bool demandesAmis = true;
  bool infos = true;

  @override
  void initState() {
    super.initState();
    chargerPreferences();
  }

  Future<void> chargerPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    // Cache local instantané (et repli hors connexion).
    if (mounted) {
      setState(() {
        notifications = prefs.getBool("notif_activées") ?? true;
        embouteillages = prefs.getBool("notif_embouteillages") ?? true;
        routesBloquees = prefs.getBool("notif_routes_bloquees") ?? true;
        messages = prefs.getBool("notif_messages") ?? true;
        demandesAmis = prefs.getBool("notif_demandes_amis") ?? true;
        infos = prefs.getBool("notif_infos") ?? true;
      });
    }

    final serveur = await SupabaseService().mesPreferencesNotifications();
    if (!mounted) return;
    setState(() {
      notifications = prefs.getBool("notif_activées") ?? true;
      embouteillages = prefs.getBool("notif_embouteillages") ?? true;
      routesBloquees = prefs.getBool("notif_routes_bloquees") ?? true;
      publicationsPages = prefs.getBool("notif_publications_pages") ?? true;
      reponsesCommentaires =
          prefs.getBool("notif_reponses_commentaires") ?? true;
      notifications = serveur['push_actif'] as bool? ?? notifications;
      embouteillages = serveur['embouteillages'] as bool? ?? embouteillages;
      routesBloquees = serveur['routes_bloquees'] as bool? ?? routesBloquees;
      messages = serveur['messages'] as bool? ?? messages;
      demandesAmis = serveur['demandes_amis'] as bool? ?? demandesAmis;
      infos = serveur['infos'] as bool? ?? infos;
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
    await prefs.setBool("notif_messages", messages);
    await prefs.setBool("notif_demandes_amis", demandesAmis);
    await prefs.setBool("notif_infos", infos);

    // Source de vérité serveur : c'est elle que l'Edge Function de push lit.
    await SupabaseService().definirPreferencesNotifications({
      'push_actif': notifications,
      'embouteillages': embouteillages,
      'routes_bloquees': routesBloquees,
      'messages': messages,
      'demandes_amis': demandesAmis,
      'infos': infos,
    });
  }

  Widget _switch({
    required String titre,
    String? sousTitre,
    required bool valeur,
    required ValueChanged<bool>? onChanged,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return SwitchListTile(
      title: Text(titre),
      subtitle: sousTitre == null ? null : Text(sousTitre),
      value: valeur,
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
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Notifications"), centerTitle: true),
      body: ListView(
        children: [
          _switch(
            titre: "Activer les notifications",
            sousTitre: "Les réglages sont synchronisés avec votre compte.",
            valeur: notifications,
            onChanged: (value) {
              setState(() {
                notifications = value;
                if (!notifications) {
                  embouteillages = false;
                  routesBloquees = false;
                  messages = false;
                  demandesAmis = false;
                  infos = false;
                }
              });
              sauvegarderPreferences();
            },
          ),
          const Divider(),
          _switch(
            titre: "Alertes embouteillages",
            valeur: embouteillages,
            onChanged: notifications
                ? (value) {
                    setState(() => embouteillages = value);
                    sauvegarderPreferences();
                  }
                : null,
          ),
          const Divider(),
          _switch(
            titre: "Alertes routes bloquées",
            valeur: routesBloquees,
            onChanged: notifications
                ? (value) {
                    setState(() => routesBloquees = value);
                    sauvegarderPreferences();
                  }
                : null,
          ),
          const Divider(),
          _switch(
            titre: "Publications des pages suivies",
            valeur: publicationsPages,
            onChanged: notifications
                ? (value) {
                    setState(() => publicationsPages = value);
                    sauvegarderPreferences();
                  }
                : null,
          ),
          const Divider(),
          _switch(
            titre: "Réponses à mes commentaires",
            valeur: reponsesCommentaires,
            onChanged: notifications
                ? (value) {
                    setState(() => reponsesCommentaires = value);
                    sauvegarderPreferences();
                  }
                : null,
          ),
          const Divider(),
          _switch(
            titre: "Nouveaux messages",
            valeur: messages,
            onChanged: notifications
                ? (value) {
                    setState(() => messages = value);
                    sauvegarderPreferences();
                  }
                : null,
          ),
          const Divider(),
          _switch(
            titre: "Demandes d’amis",
            valeur: demandesAmis,
            onChanged: notifications
                ? (value) {
                    setState(() => demandesAmis = value);
                    sauvegarderPreferences();
                  }
                : null,
          ),
          const Divider(),
          _switch(
            titre: "Nouvelles informations du fil",
            valeur: infos,
            onChanged: notifications
                ? (value) {
                    setState(() => infos = value);
                    sauvegarderPreferences();
                  }
                : null,
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 24, 20, 24),
            child: Text(
              "Les notifications push nécessitent l’autorisation du système. "
              "Si vous les avez refusées, réactivez-les dans les réglages du "
              "téléphone.",
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
