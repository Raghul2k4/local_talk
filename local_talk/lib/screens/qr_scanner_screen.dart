import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/room_invite.dart';
import '../theme/app_theme.dart';

/// Live camera scanner that returns a parsed [RoomInvite].
///
/// Reports failures as sentences rather than exceptions: "that QR code is not
/// a LocalTalk invite" is something the user can act on, whereas a
/// `FormatException` from the JSON parser is not.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    // Only codes are of interest, and restricting the format makes the scanner
    // both faster and less trigger-happy.
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    // Guard against delivering more than once: `noDuplicates` reduces repeats
    // but does not guarantee a single callback across a re-acquisition.
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      try {
        final invite = RoomInvite.decode(raw);
        _handled = true;
        Navigator.of(context).pop(invite);
        return;
      } on RoomInviteException catch (e) {
        // Show the reason and keep scanning — the user is probably just
        // pointed at the wrong code, or holding it too far away.
        _handled = true;
        _showError(e.message);
        return;
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
    // Allow another attempt after the message is seen, rather than leaving the
    // user staring at a scanner that silently stopped working.
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _handled = false);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan the host’s code'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            onPressed: () => _controller.toggleTorch(),
            icon: const Icon(Icons.flashlight_on_rounded),
            tooltip: 'Toggle torch',
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _CameraUnavailable(
              message: switch (error.errorCode) {
                MobileScannerErrorCode.permissionDenied =>
                  'LocalTalk needs the camera to scan the host’s QR code. '
                      'You can allow it in Settings, or enter the address '
                      'manually instead.',
                _ =>
                  'The camera could not be started. Close any other app using '
                      'it, or enter the address manually.',
              },
              onManualEntry: () => Navigator.of(context).pop(),
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  border: Border.all(color: AppTheme.primary, width: 3),
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 48,
            child: Column(
              children: [
                const Text(
                  'Point the camera at the QR code on the host screen.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Enter the address manually',
                    style: TextStyle(color: AppTheme.secondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown in place of the preview when the camera cannot run.
class _CameraUnavailable extends StatelessWidget {
  final String message;
  final VoidCallback onManualEntry;

  const _CameraUnavailable({
    required this.message,
    required this.onManualEntry,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_rounded,
                  color: AppTheme.textSecondary, size: 48),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onManualEntry,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.secondary,
                  foregroundColor: Colors.black,
                ),
                child: const Text('Enter address manually'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}