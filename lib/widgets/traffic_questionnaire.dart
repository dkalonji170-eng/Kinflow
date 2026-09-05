import 'package:flutter/material.dart';

class TrafficQuestionnaire extends StatelessWidget {

  final Function(String) onChoix;

  const TrafficQuestionnaire({
    super.key,
    required this.onChoix,
  });


  Widget choixTrafic(String texte, Color couleur) {

    return ListTile(

      leading: Icon(
        Icons.circle,
        color: couleur,
        size: 18,
      ),

      title: Text(
        texte,
        style: const TextStyle(
          fontSize: 17,
        ),
      ),

      onTap: () {
        onChoix(texte);
      },

    );

  }


  @override
  Widget build(BuildContext context) {

    return Center(

      child: Card(

        elevation: 8,

        margin: const EdgeInsets.all(25),

        child: Padding(

          padding: const EdgeInsets.all(25),

          child: Column(

            mainAxisSize: MainAxisSize.min,

            children: [

              const Text(

                "Pour accéder au trafic,\n"
                "veuillez indiquer l'état de la route autour de vous.",

                textAlign: TextAlign.center,

                style: TextStyle(

                  fontSize: 18,

                  fontWeight: FontWeight.bold,

                ),

              ),

              const SizedBox(height: 25),

              choixTrafic(
                "Fluide",
                const Color(0xFFAAE600),
              ),

              choixTrafic(
                "Embouteillages léger",
                Colors.orange,
              ),

              choixTrafic(
                "Gros embouteillages",
                Colors.red,
              ),

              choixTrafic(
                "Route bloquée",
                Colors.black,
              ),

            ],

          ),

        ),

      ),

    );

  }

}