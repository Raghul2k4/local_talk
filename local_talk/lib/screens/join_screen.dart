import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/intercom_controller.dart';
import '../models/room_invite.dart';
import '../services/client_service.dart' show JoinException;
import '../theme/app_theme.dart';
import '../utils/constants.dart';
import '../utils/ip_utils.dart';
import 'intercom_screen.dart';
import 'qr_scanner_screen.dart';

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _usernameController = TextEditingController();
  final _pinController = TextEditingController();
  final _addressController = TextEditingController();

  /// Manual address entry is a fallback, not the main path, so it starts
  /// collapsed. This is the behaviour change from the original screen, where
  /// typing an IP was the only option.
  bool _showManualEntry = false;
  bool _usePin = false;
  bool _joining = false;
  String? _error;

  /// The endpoint parsed from a scanned QR. Null until a scan succeeds.
  RoomInvite? _scannedInvite;

  @override
  void initState() {
    super.initState();
    _loadDefaults();
  }

  Future<void> _loadDefaults() async {
    final appData = context.read<IntercomController>().appData;
    if (appData == null) return;
    _usernameController.text =
        appData.username == 'User' ? '' : appData.username;
    // Pre-fill the manual fallback only; the user should not see a remembered
    // address presented as if it were current.
    if (appData.lastHostIp != null) {
      _addressController.text = appData.lastHostIp!;
    }
    if (appData.rememberPin && appData.lastPin != null) {
      _pinController.text = appData.lastPin!;
      setState(() => _usePin = true);
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _pinController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _scanQr() async {
    final invite = await Navigator.of(context).push<RoomInvite>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (invite == null || !mounted) return;
    setState(() {
      _scannedInvite = invite;
      _error = null;
    });
    // Connect straight away — scanning *is* the join action.
    await _join(invite: invite);
  }

  Future<void> _join({RoomInvite? invite}) async {
    final name = _usernameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter your name so others can see you.');
      return;
    }

    // Manual mode: parse `host[:port]` up front so a bad address is reported
    // here rather than as a generic "could not reach the host" later.
    String address = '';
    int? port;
    if (invite == null) {
      final endpoint = _parseEndpoint(_addressController.text);
      if (endpoint == null) {
        setState(() => _error =
            'That does not look like an address. It should be four numbers '
            'separated by dots, for example 10.0.14.221.');
        return;
      }
      address = endpoint.host;
      port = endpoint.port;
    }

    setState(() {
      _joining = true;
      _error = null;
    });
    final controller = context.read<IntercomController>();
    try {
      await controller.joinRoom(
        address,
        name,
        pin: _usePin ? _pinController.text.trim() : null,
        invite: invite,
        port: port,
      );
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const IntercomScreen()),
      );
    } on JoinException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      // Never surface a raw exception; the controller has already recorded a
      // user-facing message on `error`.
      setState(() => _error = controller.error ??
          'Could not join the room. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final joining =
        _joining || context.watch<IntercomController>().isConnecting;

    return Scaffold(
      appBar: AppBar(title: const Text('Join a room')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            TextField(
              controller: _usernameController,
              textCapitalization: TextCapitalization.words,
              maxLength: 24,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Your name',
                hintText: 'How others will see you',
                counterText: '',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
            ),
            const SizedBox(height: 20),

            // The primary action. Scanning needs no understanding of
            // addresses, ports or subnets.
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: joining ? null : _scanQr,
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('Scan QR code'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.secondary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                'Ask the host to show their screen, then scan it.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),

            // What we learned from a scan, if any. Showing it proves the app
            // read the code and gives the user something to check.
            if (_scannedInvite != null) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.outline),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_rounded,
                        color: AppTheme.primary, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Room ${_scannedInvite!.roomId} found.',
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 12),
            const Row(
              children: [
                Expanded(child: Divider(color: AppTheme.outline)),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'or',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                ),
                Expanded(child: Divider(color: AppTheme.outline)),
              ],
            ),

            // Advanced fallback: manual endpoint entry.
            TextButton.icon(
              onPressed: joining
                  ? null
                  : () => setState(() => _showManualEntry = !_showManualEntry),
              icon: Icon(
                _showManualEntry
                    ? Icons.expand_less_rounded
                    : Icons.keyboard_alt_outlined,
              ),
              label: Text(
                _showManualEntry
                    ? 'Hide manual entry'
                    : 'Enter address manually',
              ),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.textSecondary,
              ),
            ),

            if (_showManualEntry) ...[
              const SizedBox(height: 12),
              _AddressField(controller: _addressController),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: joining ? null : () => _join(),
                  icon: const Icon(Icons.login_rounded),
                  label: const Text('Connect'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textPrimary,
                    side: const BorderSide(color: AppTheme.outline),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Room has a PIN'),
              value: _usePin,
              activeThumbColor: AppTheme.secondary,
              onChanged: (v) => setState(() => _usePin = v),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: !_usePin
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: TextField(
                        controller: _pinController,
                        keyboardType: TextInputType.number,
                        maxLength: AppConstants.pinLength,
                        obscureText: true,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        decoration: const InputDecoration(
                          labelText: 'PIN',
                          counterText: '',
                          prefixIcon: Icon(Icons.lock_outline_rounded),
                        ),
                      ),
                    ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.danger.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.danger.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        color: AppTheme.danger),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // The two things that actually fix a failed join.
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: joining ? null : _scanQr,
                      icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                      label: const Text('Try again'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.textPrimary,
                        side: const BorderSide(color: AppTheme.outline),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: joining
                          ? null
                          : () =>
                              setState(() => _showManualEntry = true),
                      icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
                      label: const Text('Enter IP'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.textPrimary,
                        side: const BorderSide(color: AppTheme.outline),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'If this keeps failing, check that both phones are on the '
                'host’s network and that their room is still open.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Splits `host[:port]` and validates the address.
///
/// Returns null when the input is unusable so the caller shows one clear
/// message instead of attempting a connection that cannot work.
({String host, int? port})? _parseEndpoint(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;

  // An optional port, so someone reading the host's details panel can paste
  // the whole endpoint instead of editing it.
  final parts = value.split(':');
  if (parts.length > 2) return null;

  final host = parts[0].trim();
  if (!IpUtils.isValidIpv4(host)) return null;

  if (parts.length == 1) return (host: host, port: null);

  final port = int.tryParse(parts[1].trim());
  if (port == null || port < 1 || port > 65535) return null;
  return (host: host, port: port);
}

/// Manual endpoint input.
///
/// Separate widget only so the hint text can show two different valid ranges
/// side by side — the app must not teach one "house" subnet, which is what the
/// old `192.168.1.42` hint did.
class _AddressField extends StatelessWidget {
  final TextEditingController controller;

  const _AddressField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.url,
      autocorrect: false,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(
        labelText: 'Host address',
        hintText: '10.0.14.221 or 192.168.1.42',
        helperText: 'Any address your host is on. You can add a port, '
            'e.g. 10.0.14.221:8080',
        prefixIcon: Icon(Icons.dns_rounded),
      ),
    );
  }
}
