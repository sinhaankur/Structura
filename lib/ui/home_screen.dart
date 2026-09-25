import 'package:flutter/material.dart';

import '../capture/capture_channel.dart';
import '../model/scan.dart';
import 'capture_screen.dart';
import 'theme.dart';

/// Landing screen. Queries what capture the device can do and says so honestly,
/// then routes into a session. Recent scans list will hang off here once
/// persistence lands.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  CaptureSupport? _support;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final s = await CaptureChannel.instance.querySupport();
    if (mounted) {
      setState(() {
        _support = s;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _support;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Insets.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: Insets.l),
              Text('Structura',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      )),
              const SizedBox(height: Insets.xs),
              Text(
                'Scan structures with your phone. View in 3D, clean, and export.',
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: Insets.l),
              if (_loading)
                const Expanded(child: Center(child: CircularProgressIndicator()))
              else ...[
                _DeviceCard(support: s),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: (s?.supported ?? false) ? _startCapture : null,
                    icon: const Icon(Icons.center_focus_strong),
                    label: const Text('New Scan'),
                  ),
                ),
                if (!(s?.supported ?? false)) ...[
                  const SizedBox(height: Insets.s),
                  Text(
                    s?.reason ?? 'This device can’t do depth capture.',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const SizedBox(height: Insets.s),
                  // With no depth sensor (simulator / non-Pro / desktop), you can
                  // still run the FULL pipeline on a realistic simulated scan —
                  // honestly labelled, so the app is demonstrable everywhere.
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _startSimulatedCapture,
                      icon: const Icon(Icons.view_in_ar_outlined),
                      label: const Text('Try a simulated scan'),
                    ),
                  ),
                ],
                const SizedBox(height: Insets.m),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _startCapture() {
    CaptureChannel.instance.simulate = false;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CaptureScreen()),
    );
  }

  void _startSimulatedCapture() {
    CaptureChannel.instance.simulate = true;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CaptureScreen()),
    );
  }
}

/// Honestly reports the capture quality the device supports — never dresses up a
/// depth-from-motion phone as LiDAR.
class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.support});
  final CaptureSupport? support;

  @override
  Widget build(BuildContext context) {
    final q = support?.quality ?? CaptureQuality.unknown;
    final ok = support?.supported ?? false;
    final (icon, tint, title, sub) = switch (q) {
      CaptureQuality.lidar => (
          Icons.sensors,
          const Color(0xFF4CC2FF),
          'LiDAR ready',
          'Dedicated depth sensor — cleanest scans.'
        ),
      CaptureQuality.depthFromMotion => (
          Icons.motion_photos_on,
          const Color(0xFFFFB454),
          'Depth (motion)',
          'No ToF sensor — works, but noisier. Move slowly for best results.'
        ),
      CaptureQuality.unknown => (
          Icons.help_outline,
          Colors.white38,
          ok ? 'Depth capture' : 'No depth capture',
          ok ? 'Ready to scan.' : 'This device lacks a supported depth API.'
        ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Insets.m),
        child: Row(
          children: [
            Icon(icon, color: tint, size: 34),
            const SizedBox(width: Insets.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
