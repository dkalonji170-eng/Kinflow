import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/diagnostics_service.dart';

/// Scanner de QR code « ami ». Retourne le **code AMI** lu (String), ou null
/// si l'utilisateur annule. Accepte un code brut, un contenu de la forme
/// `KINFLOW:CODE` ou une URL qui contient le code.
class ScanQrAmiScreen extends StatefulWidget {
  const ScanQrAmiScreen({super.key});

  @override
  State<ScanQrAmiScreen> createState() => _ScanQrAmiScreenState();
}

class _ScanQrAmiScreenState extends State<ScanQrAmiScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _traite = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Extrait un code AMI d'un texte scanné : code brut, ou vue d'une URL qui
  /// contient `ami/CODE`. Retourne null si rien d'exploitable.
  static String? extraireCode(String? brut) {
    if (brut == null) return null;
    final texte = brut.trim();
    if (texte.isEmpty) return null;

    const marqueur = 'ami/';
    final index = texte.toLowerCase().lastIndexOf(marqueur);
    final source =
        index >= 0 ? texte.substring(index + marqueur.length) : texte;

    final code = source.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return code.isEmpty ? null : code;
  }

  void _onDetect(BarcodeCapture capture) {
    if (_traite || !mounted) return;
    for (final barcode in capture.barcodes) {
      final code = extraireCode(barcode.rawValue);
      if (code != null) {
        _traite = true;
        Journal.i('SOCIAL', 'QR ami scanné');
        Navigator.pop(context, code);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scanner un QR ami')),
      backgroundColor: Colors.black,
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // Viseur : un carré clair au centre.
          IgnorePointer(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            bottom: 48,
            left: 24,
            right: 24,
            child: Text(
              'Vise le QR code affiché sur le profil de ton ami(e).',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
