import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/supabase_service.dart';
import '../widgets/carte_publication.dart';

/// Rédaction d'un reportage : titre, texte libre, photos, type et lieu.
///
/// Aucune validation avant publication : l'espace est privé et l'auteur est
/// connu de ses lecteurs. En revanche, le lien peut être révoqué et un
/// reportage peut être supprimé à tout moment.
class PublierPublicationScreen extends StatefulWidget {
  const PublierPublicationScreen({
    super.key,
    required this.jeton,
    required this.dossier,
  });

  /// Jeton de l'espace dans lequel on publie (le mien ou celui d'un ami).
  final String jeton;

  /// Identifiant du propriétaire de l'espace : les photos sont rangées dans
  /// son dossier Storage, pour que ses lecteurs puissent les voir.
  final String dossier;

  @override
  State<PublierPublicationScreen> createState() =>
      _PublierPublicationScreenState();
}

class _PublierPublicationScreenState extends State<PublierPublicationScreen> {
  static const int _maxPhotos = 4;

  final SupabaseService _service = SupabaseService();
  final TextEditingController _titre = TextEditingController();
  final TextEditingController _contenu = TextEditingController();
  final TextEditingController _lieu = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  String _type = 'info';
  final List<({XFile fichier, Uint8List octets})> _photos = [];
  bool _envoi = false;
  bool _anonyme = false;

  @override
  void dispose() {
    _titre.dispose();
    _contenu.dispose();
    _lieu.dispose();
    super.dispose();
  }

  Future<void> _ajouterPhoto(ImageSource source) async {
    if (_photos.length >= _maxPhotos || _envoi) return;
    try {
      final fichier = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 82,
      );
      if (fichier == null) return;
      final octets = await fichier.readAsBytes();
      if (!mounted) return;
      setState(() {
        _photos.add((fichier: fichier, octets: octets));
      });
    } catch (e) {
      if (!mounted) return;
      _snack('Photo indisponible : $e');
    }
  }

  Future<void> _choisirSource() async {
    if (_photos.length >= _maxPhotos || _envoi) return;
    final choix = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choisir dans la galerie'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choix != null) {
      await _ajouterPhoto(choix);
    }
  }

  String _extension(XFile fichier) {
    final nom = fichier.name.toLowerCase();
    final point = nom.lastIndexOf('.');
    if (point == -1 || point == nom.length - 1) return 'jpg';
    final ext = nom.substring(point + 1);
    return ext.length <= 5 ? ext : 'jpg';
  }

  Future<void> _publier() async {
    if (_envoi) return;
    final titre = _titre.text.trim();
    final contenu = _contenu.text.trim();
    if (titre.length < 3) {
      _snack('Donne un titre de 3 caractères minimum.');
      return;
    }
    if (contenu.isEmpty) {
      _snack('Écris ton reportage avant de publier.');
      return;
    }

    setState(() => _envoi = true);
    final chemins = <String>[];
    for (var i = 0; i < _photos.length; i++) {
      final chemin = await _service.televerserPhotoPublication(
        octets: _photos[i].octets,
        extension: _extension(_photos[i].fichier),
        dossier: widget.dossier,
        index: i,
      );
      if (chemin == null) {
        if (!mounted) return;
        setState(() => _envoi = false);
        _snack(
          'Photo non envoyée : '
          '${_service.derniereErreur ?? 'vérifie ta connexion.'}',
        );
        return;
      }
      chemins.add(chemin);
    }

    final id = await _service.publierPublication(
      jeton: widget.jeton,
      titre: titre,
      contenu: contenu,
      type: _type,
      lieu: _lieu.text.trim().isEmpty ? null : _lieu.text.trim(),
      photos: chemins,
      anonyme: _anonyme,
    );
    if (!mounted) return;
    if (id == null) {
      setState(() => _envoi = false);
      _snack(
        'Publication non enregistrée : '
        '${_service.derniereErreur ?? 'réessaie.'}',
      );
      return;
    }
    Navigator.pop(context, true);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ma page'),
        actions: [
          TextButton(
            onPressed: _envoi ? null : _publier,
            child: _envoi
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Publier'),
          ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _envoi,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            TextField(
              controller: _titre,
              maxLength: 120,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Titre',
                hintText: 'Ex. : Ngaba, le pont est coupé',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _contenu,
              maxLength: 2000,
              minLines: 6,
              maxLines: 14,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Ton reportage',
                hintText:
                    'Ce que tu as vu, où, quand, ce que les gens doivent '
                    'savoir…',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _lieu,
              maxLength: 80,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Lieu (facultatif)',
                hintText: 'Ex. : Ngaba, avenue Kianza',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Type',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final type in const [
                  'trafic',
                  'eau',
                  'courant',
                  'internet',
                  'securite',
                  'info',
                ])
                  _puceType(type, theme),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Text(
                  'Photos',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${_photos.length}/$_maxPhotos',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 96,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < _photos.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.memory(
                              _photos[i].octets,
                              width: 96,
                              height: 96,
                              fit: BoxFit.cover,
                            ),
                          ),
                          Positioned(
                            top: 2,
                            right: 2,
                            child: GestureDetector(
                              onTap: () => setState(() => _photos.removeAt(i)),
                              child: const CircleAvatar(
                                radius: 11,
                                backgroundColor: Colors.black54,
                                child: Icon(
                                  Icons.close,
                                  size: 14,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_photos.length < _maxPhotos)
                    InkWell(
                      onTap: _choisirSource,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: Icon(
                          Icons.add_a_photo_outlined,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SwitchListTile(
              value: _anonyme,
              onChanged: (valeur) => setState(() => _anonyme = valeur),
              contentPadding: EdgeInsets.zero,
              title: const Text('Publier anonymement'),
              subtitle: const Text(
                'Ton nom et ton avatar seront remplacés par « Anonyme ».',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Seules les personnes qui ont le lien de ton espace pourront '
              'lire ce reportage.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _puceType(String type, ThemeData theme) {
    final (libelle, icone, couleur) = CartePublication.typeInfos(type);
    final choisi = _type == type;
    return ChoiceChip(
      selected: choisi,
      onSelected: (_) => setState(() => _type = type),
      avatar: Icon(icone, size: 16, color: choisi ? Colors.white : couleur),
      label: Text(libelle),
      labelStyle: TextStyle(
        color: choisi ? Colors.white : theme.colorScheme.onSurface,
        fontWeight: choisi ? FontWeight.w700 : FontWeight.w500,
      ),
      selectedColor: couleur,
      showCheckmark: false,
    );
  }
}
