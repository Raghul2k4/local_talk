import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/intercom_controller.dart';
import '../services/client_service.dart' show JoinException;
import '../theme/app_theme.dart';
import '../utils/constants.dart';
import '../utils/network_utils.dart';
import 'intercom_screen.dart';

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _hostIpController = TextEditingController();
  final _usernameController = TextEditingController();
  final _pinController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _usePin = false;
  bool _joining = false;
  String? _error;

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
    if (appData.lastHostIp != null) {
      _hostIpController.text = appData.lastHostIp!;
    }
    if (appData.rememberPin && appData.lastPin != null) {
      _pinController.text = appData.lastPin!;
      setState(() => _usePin = true);
    }
  }

  @override
  void dispose() {
    _hostIpController.dispose();
    _usernameController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _joinIntercom() async {
    if (!_formKey.currentState!.validate()) return;

    final isWifi = await NetworkUtils.isWifiConnected();
    if (!mounted) return;
    if (!isWifi) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'No Wi-Fi detected. Connect to the host\'s hotspot first, then try joining.'),
        ),
      );
      return;
    }

    setState(() {
      _joining = true;
      _error = null;
    });
    final controller = context.read<IntercomController>();
    try {
      await controller.joinRoom(
        _hostIpController.text.trim(),
        _usernameController.text.trim(),
        pin: _usePin ? _pinController.text.trim() : null,
      );
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const IntercomScreen()),
      );
    } on JoinException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Something went wrong: $e');
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
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Enter the address shown on the host device.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _hostIpController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Host IP address',
                  hintText: '192.168.1.42',
                  prefixIcon: Icon(Icons.dns_rounded),
                ),
                validator: (v) {
                  final value = v?.trim() ?? '';
                  if (value.isEmpty) return 'Enter the host IP address';
                  final ip = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
                  if (!ip.hasMatch(value)) {
                    return 'Use the format 192.168.1.42';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _usernameController,
                textCapitalization: TextCapitalization.words,
                maxLength: 24,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Your name',
                  hintText: 'How others will see you',
                  counterText: '',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Enter your name' : null,
              ),
              const SizedBox(height: 16),
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
                        child: TextFormField(
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
                          validator: (v) => (v == null ||
                                  v.length != AppConstants.pinLength)
                              ? 'Enter the ${AppConstants.pinLength}-digit PIN'
                              : null,
                        ),
                      ),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: joining ? null : _joinIntercom,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.secondary,
                  foregroundColor: Colors.black,
                ),
                child: joining
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: Colors.black),
                      )
                    : const Text('Join the room'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.danger.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: AppTheme.danger.withValues(alpha: 0.4)),
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
                              color: AppTheme.textPrimary, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
