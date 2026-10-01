import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../controllers/intercom_controller.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _usernameController;
  bool _testing = false;
  double _level = 0;
  StreamSubscription<double>? _levelSub;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController(
        text: context.read<IntercomController>().username);
  }

  @override
  void dispose() {
    _levelSub?.cancel();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _saveUsername() async {
    final controller = context.read<IntercomController>();
    final name = _usernameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name cannot be empty')),
      );
      return;
    }
    await controller.setUsername(name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Name saved')),
    );
  }

  Future<bool> _ensureMicPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> _testMicrophone() async {
    if (_testing) return;
    final granted = await _ensureMicPermission();
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Microphone permission is required.'),
          action: SnackBarAction(
            label: 'SETTINGS',
            onPressed: openAppSettings,
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    final controller = context.read<IntercomController>();
    var audio = controller.audioService;
    if (audio == null || !audio.isReady) {
      final ok = await controller.recreateAudioService();
      if (!ok || !mounted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not access the microphone.')),
          );
        }
        return;
      }
      audio = controller.audioService;
    }
    if (audio == null) return;
    final audioService = audio;
    setState(() => _testing = true);
    await audioService.startRecording();
    _levelSub = audioService.levelStream.listen((lvl) {
      if (mounted) setState(() => _level = lvl);
    });
    Timer(const Duration(seconds: 3), () async {
      await audioService.stopRecording();
      await _levelSub?.cancel();
      if (mounted) {
        setState(() {
          _testing = false;
          _level = 0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mic test finished')),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'PROFILE',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _usernameController,
            textCapitalization: TextCapitalization.words,
            maxLength: 24,
            decoration: const InputDecoration(
              labelText: 'Your name',
              counterText: '',
              prefixIcon: Icon(Icons.person_outline_rounded),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _saveUsername,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Save name'),
            ),
          ),
          const Divider(height: 32),
          const Text(
            'MICROPHONE',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          if (_testing) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: _level),
                duration: const Duration(milliseconds: 80),
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 10,
                  backgroundColor: AppTheme.surfaceHigh,
                  color: AppTheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Say something…',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ] else
            OutlinedButton.icon(
              onPressed: _testMicrophone,
              icon: const Icon(Icons.mic_rounded),
              label: const Text('Test microphone (3s)'),
            ),
          const Divider(height: 32),
          const Text(
            'ABOUT',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.outline),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LocalTalk v1.1',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                SizedBox(height: 4),
                Text(
                  'Local Wi-Fi push-to-talk intercom. '
                  'Audio never leaves your network.',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Audio: PCM16 · 16 kHz over WebSocket on port 8080',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Traffic is unencrypted on your local network, and a room PIN '
                  'only deters casual joiners. Use a trusted Wi-Fi network.',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11.5,
                    height: 1.35,
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
