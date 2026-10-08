import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../controllers/intercom_controller.dart';
import '../theme/app_theme.dart';
import '../utils/ip_utils.dart';
import '../utils/network_utils.dart';
import 'host_ready_screen.dart';

class HostScreen extends StatefulWidget {
  const HostScreen({super.key});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  final _roomNameController = TextEditingController();
  final _pinController = TextEditingController();
  final _hotspotSsidController = TextEditingController();
  final _hotspotPasswordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String? _localIp;
  bool _usePin = false;
  bool _useHotspot = false;
  bool _starting = false;
  bool _obscurePin = true;
  bool _obscureHotspotPassword = true;

  @override
  void initState() {
    super.initState();
    _loadIp();
    _loadDefaults();
  }

  Future<void> _loadIp() async {
    final ip = await IpUtils.getUsableIp();
    if (mounted) setState(() => _localIp = ip);
  }

  Future<void> _loadDefaults() async {
    final appData = context.read<IntercomController>().appData;
    if (appData == null) return;
    if (appData.lastRoomName != null) {
      _roomNameController.text = appData.lastRoomName!;
    }
    if (appData.rememberPin && appData.lastPin != null) {
      _pinController.text = appData.lastPin!;
      setState(() => _usePin = true);
    }
  }

  @override
  void dispose() {
    _roomNameController.dispose();
    _pinController.dispose();
    _hotspotSsidController.dispose();
    _hotspotPasswordController.dispose();
    super.dispose();
  }

  /// Requests what hotspot mode needs on this OS version.
  ///
  /// Android 12 (API 31) split Wi-Fi control out of the location permission:
  /// `startLocalOnlyHotspot` now throws a SecurityException unless
  /// NEARBY_WIFI_DEVICES is granted, and asking for location alone is not
  /// enough. Both are requested because older versions still gate on
  /// location, and requesting an already-granted permission is a no-op.
  Future<bool> _ensureHotspotPermissions() async {
    if (!Platform.isAndroid) return true;

    // Pre-Android 12 gates hotspot creation on location.
    final location = await Permission.location.request();
    if (!location.isGranted) {
      _showPermissionSnackBar(
        'Location permission is required to start a hotspot.',
      );
      return false;
    }

    // Android 12+ additionally requires NEARBY_WIFI_DEVICES.
    final nearby = await Permission.nearbyWifiDevices.request();
    if (!nearby.isGranted) {
      _showPermissionSnackBar(
        '“Nearby devices” permission is required to start a hotspot '
        'on Android 12 and newer.',
      );
      return false;
    }

    return true;
  }

  void _showPermissionSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: const SnackBarAction(
          label: 'SETTINGS',
          onPressed: openAppSettings,
        ),
      ),
    );
  }

  Future<void> _createIntercom() async {
    if (!_formKey.currentState!.validate()) return;

    final isWifi = await NetworkUtils.isWifiConnected();
    if (!mounted) return;
    if (!isWifi && !_useHotspot) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'No Wi-Fi connection found. Connect to Wi-Fi or enable hotspot mode.'),
        ),
      );
      return;
    }

    if (_useHotspot) {
      final granted = await _ensureHotspotPermissions();
      if (!granted || !mounted) return;
    }

    setState(() => _starting = true);
    final controller = context.read<IntercomController>();
    final roomName = _roomNameController.text.trim();
    final pin = _usePin ? _pinController.text.trim() : null;

    final appData = controller.appData;
    await appData?.setLastRoomName(roomName);
    await appData?.setRememberPin(_usePin);
    await appData?.setLastPin(_usePin ? pin : null);

    await controller.startHost(
      roomName,
      pin: pin,
      useHotspot: _useHotspot,
      hotspotSsid: _useHotspot ? _hotspotSsidController.text : null,
      hotspotPassword: _useHotspot ? _hotspotPasswordController.text : null,
    );

    if (!mounted) return;
    setState(() => _starting = false);
    if (controller.setupStage == RoomSetupStage.ready) {
      // Go to the QR screen, not straight into the room: the host's job now
      // is to show the code, not to start talking.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HostReadyScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final starting =
        _starting || context.watch<IntercomController>().isConnecting;
    final isAndroid = Platform.isAndroid;

    return Scaffold(
      appBar: AppBar(title: const Text('Create a room')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'This device becomes the intercom server.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _roomNameController,
                textCapitalization: TextCapitalization.words,
                maxLength: 32,
                decoration: const InputDecoration(
                  labelText: 'Room name',
                  hintText: 'e.g. Game Night',
                  counterText: '',
                  prefixIcon: Icon(Icons.meeting_room_outlined),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Enter a room name'
                    : null,
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Protect with a PIN'),
                subtitle: const Text(
                  'Others must enter it to join',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
                value: _usePin,
                activeThumbColor: AppTheme.primary,
                onChanged: (v) => setState(() => _usePin = v),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: !_usePin
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: TextFormField(
                          controller: _pinController,
                          keyboardType: TextInputType.number,
                          obscureText: _obscurePin,
                          maxLength: 4,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: InputDecoration(
                            labelText: 'PIN (4 digits)',
                            counterText: '',
                            prefixIcon: const Icon(Icons.lock_outline_rounded),
                            suffixIcon: IconButton(
                              icon: Icon(_obscurePin
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined),
                              onPressed: () =>
                                  setState(() => _obscurePin = !_obscurePin),
                            ),
                          ),
                          validator: (v) => (v == null || v.length != 4)
                              ? 'Enter a 4-digit PIN'
                              : null,
                        ),
                      ),
              ),
              if (isAndroid) ...[
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Create Hotspot'),
                  subtitle: const Text(
                    'Share connection without Wi-Fi (Android only)',
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                  value: _useHotspot,
                  activeThumbColor: AppTheme.primary,
                  onChanged: (v) => setState(() => _useHotspot = v),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  child: !_useHotspot
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Column(
                            children: [
                              TextFormField(
                                controller: _hotspotSsidController,
                                textCapitalization: TextCapitalization.words,
                                decoration: const InputDecoration(
                                  labelText: 'Hotspot name (SSID)',
                                  hintText: 'e.g. LocalTalk_Party',
                                  counterText: '',
                                  prefixIcon:
                                      Icon(Icons.wifi_tethering_rounded),
                                ),
                                validator: (v) =>
                                    (v == null || v.trim().isEmpty)
                                        ? 'Enter a hotspot name'
                                        : null,
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _hotspotPasswordController,
                                obscureText: _obscureHotspotPassword,
                                decoration: InputDecoration(
                                  labelText: 'Password (8+ characters)',
                                  hintText: 'Min. 8 characters',
                                  counterText: '',
                                  prefixIcon:
                                      const Icon(Icons.lock_outline_rounded),
                                  suffixIcon: IconButton(
                                    icon: Icon(_obscureHotspotPassword
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined),
                                    onPressed: () => setState(() =>
                                        _obscureHotspotPassword =
                                            !_obscureHotspotPassword),
                                  ),
                                ),
                                validator: (v) {
                                  final value = v?.trim() ?? '';
                                  if (value.isEmpty) return 'Enter a password';
                                  if (value.length < 8) {
                                    return 'Password must be at least 8 characters';
                                  }
                                  return null;
                                },
                              ),
                            ],
                          ),
                        ),
                ),
              ],
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.outline),
                ),
                child: _useHotspot
                    ? Row(
                        children: [
                          const Icon(Icons.wifi_tethering_rounded,
                              color: AppTheme.primary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Hotspot IP (after starting)',
                                  style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 12),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _localIp != null
                                      ? '$_localIp:8080'
                                      : 'Detecting…',
                                  style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          const Icon(Icons.wifi_rounded,
                              color: AppTheme.primary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Friends will join with this address',
                                  style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 12),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _localIp != null
                                      ? '$_localIp:8080'
                                      : 'Detecting…',
                                  style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_localIp != null)
                            IconButton(
                              onPressed: () {
                                Clipboard.setData(
                                    ClipboardData(text: _localIp!));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('IP address copied')),
                                );
                              },
                              icon: const Icon(Icons.copy_rounded, size: 20),
                              tooltip: 'Copy IP',
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: starting ? null : _createIntercom,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.black,
                ),
                child: starting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: Colors.black),
                      )
                    : const Text('Start the room'),
              ),
              if (context.watch<IntercomController>().error != null) ...[
                const SizedBox(height: 16),
                // When the OS refused to let us start a hotspot, say exactly
                // that and offer the settings trip. Pretending the app can
                // toggle a system switch would be worse than an honest
                // instruction.
                if (context.watch<IntercomController>().hotspotNeedsUserAction)
                  _HotspotGuidanceCard(
                      message:
                          context.read<IntercomController>().error!)
                else
                  _ErrorCard(
                      message: context.read<IntercomController>().error!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when the OS blocked a programmatic hotspot.
///
/// Android 10+ removed `WifiManager.setWifiApEnabled` for third-party apps, so
/// this is a normal outcome rather than a failure to work around. The card
/// tells the user what to do and hands them the settings screen; it does not
/// claim LocalTalk can do it for them.
class _HotspotGuidanceCard extends StatelessWidget {
  final String message;

  const _HotspotGuidanceCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.wifi_tethering_rounded, color: AppTheme.primary),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Local network required',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            message.contains('Wi-Fi')
                ? 'Connect to Wi-Fi instead — the room works the same way.'
                : 'After turning it on, come back and start the room again.',
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => openAppSettings(),
                  icon: const Icon(Icons.settings_rounded, size: 18),
                  label: const Text('Open settings'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textPrimary,
                    side: const BorderSide(color: AppTheme.outline),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppTheme.danger),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
