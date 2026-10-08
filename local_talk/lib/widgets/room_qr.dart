import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/room_invite.dart';
import '../theme/app_theme.dart';

/// Renders a [RoomInvite] as a QR code.
///
/// Kept as its own widget so the same visual is reused wherever an invite is
/// shown, and so the "why is there no QR" case is handled in one place.
class RoomQr extends StatelessWidget {
  final RoomInvite? invite;
  final double size;

  const RoomQr({super.key, required this.invite, this.size = 220});

  @override
  Widget build(BuildContext context) {
    final invite = this.invite;
    if (invite == null) {
      // Never render a QR for an unknown endpoint: a code that scans but does
      // not connect is a worse experience than no code at all.
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.outline),
        ),
        child: const Text(
          'Preparing the address…',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        // A white quiet zone is what makes a QR scannable reliably; the app is
        // dark-themed, so the panel is light deliberately.
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: QrImageView(
        data: invite.encode(),
        version: QrVersions.auto,
        size: size,
        // Room theme is dark, so the modules must be dark on white. The
        // explicit white container above already guarantees contrast; this
        // keeps the widget's own default in step with it.
        backgroundColor: Colors.white,
        padding: EdgeInsets.zero,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
      ),
    );
  }
}

/// A labelled value with a copy button, used in the connection-details panel.
class CopyableRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasise;

  const CopyableRow({
    super.key,
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.outline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: emphasise ? 16 : 14,
                    fontWeight: emphasise ? FontWeight.w700 : FontWeight.w600,
                    letterSpacing: emphasise ? 0.3 : 0,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('$label copied')),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            tooltip: 'Copy $label',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}