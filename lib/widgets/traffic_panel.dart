import 'package:flutter/material.dart';

import '../services/diagnostics_service.dart';

class TrafficPanel extends StatelessWidget {

  final VoidCallback onPosition;
  final bool chargementPosition;
  final VoidCallback onRecherche;
  final VoidCallback? onMonApplication;

  const TrafficPanel({
    super.key,
    required this.onPosition,
    required this.chargementPosition,
    required this.onRecherche,
    this.onMonApplication,
  });


  @override
  Widget build(BuildContext context) {

    final couleurTexte =
        Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : Colors.black;

    final styleBouton =
        OutlinedButton.styleFrom(
          side: BorderSide(color: couleurTexte),
        );


    return Container(

      padding: const EdgeInsets.only(bottom: 8),

      child: Column(

        mainAxisSize: MainAxisSize.min,

        children: [

          SizedBox(
            height: 46,
            child: OutlinedButton.icon(
              onPressed: onPosition,
              style: styleBouton,
              icon: Icon(
                Icons.location_on,
                size: 20,
                color: couleurTexte,
              ),
              label: chargementPosition
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : Text(
                      "Ma position",
                      style: TextStyle(
                        color: couleurTexte,
                        fontSize: 14,
                      ),
                    ),
            ),
          ),

          const SizedBox(height: 6),

          SizedBox(
            height: 46,
            child: OutlinedButton.icon(
              onPressed: onRecherche,
              style: styleBouton,
              icon: Icon(
                Icons.search,
                size: 20,
                color: couleurTexte,
              ),
              label: Text(
                "Rechercher un lieu",
                style: TextStyle(
                  color: couleurTexte,
                  fontSize: 14,
                ),
              ),
            ),
          ),

          const SizedBox(height: 6),

          SizedBox(
            height: 46,
            child: ListenableBuilder(
              listenable: Journal.instance,
              builder: (context, _) => OutlinedButton.icon(
                onPressed: onMonApplication,
                style: styleBouton,
                icon: Badge.count(
                  count: Journal.instance.erreursNonVues,
                  isLabelVisible: Journal.instance.erreursNonVues > 0,
                  backgroundColor: Colors.red,
                  child: Icon(
                    Icons.bug_report,
                    size: 20,
                    color: couleurTexte,
                  ),
                ),
                label: Text(
                  "Mon application",
                  style: TextStyle(
                    color: couleurTexte,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),

        ],

      ),

    );

  }

}
