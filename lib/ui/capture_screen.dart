import 'dart:async';

import 'package:flutter/material.dart';

import '../capture/capture_channel.dart';
import '../model/scan.dart';
import 'theme.dart';
import 'viewer_screen.dart';

/// Live capture. Shows the camera + depth-mesh overlay (rendered by the native
/// AR view behind this Flutter chrome), a coverage ring, and start/stop.
///
/// The native side owns the AR camera surface (a platform view); this screen is
/// the HUD over it plus the session controls.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _channel = CaptureChannel.instance;
  StreamSubscription<CaptureEvent>? _sub;
  double _coverage = 0;
  int _vertexCount = 0;
  bool _scanning = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  Future<void> _begin() async {
    await _channel.start();
    _sub = _channel.events().listen((e) {
      if (!mounted) return;
      setState(() {
        _coverage = e.coverage;
        _vertexCount = e.vertexCount;
      });
    });
    setState(() => _scanning = true);
  }

  Future<void> _finish() async {
    setState(() => _finishing = true);
    await _sub?.cancel();
    final scan = await _channel.finish();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ViewerScreen(scan: scan)),
    );
  }

  Future<void> _cancel() async {
    await _sub?.cancel();
    await _channel.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // The native AR camera + live depth-mesh overlay renders here. Until the
          // plugin is wired, this is a placeholder so the HUD is developable in
          // the simulator.
          const Positioned.fill(child: _ArSurfacePlaceholder()),

          // top bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(Insets.m),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: _finishing ? null : _cancel,
                    icon: const Icon(Icons.close),
                  ),
                  const Spacer(),
                  _CoverageChip(coverage: _coverage, verts: _vertexCount),
                ],
              ),
            ),
          ),

          // bottom controls
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: Insets.l),
                child: _finishing
                    ? const _FinishingIndicator()
                    : _CaptureButton(
                        scanning: _scanning,
                        onFinish: _finish,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverageChip extends StatelessWidget {
  const _CoverageChip({required this.coverage, required this.verts});
  final double coverage;
  final int verts;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              value: coverage.clamp(0, 1),
              strokeWidth: 2.5,
              backgroundColor: Colors.white24,
            ),
          ),
          const SizedBox(width: 10),
          Text('${(coverage * 100).round()}%  ·  ${_fmt(verts)} pts',
              style: const TextStyle(fontSize: 13, color: Colors.white)),
        ],
      ),
    );
  }

  static String _fmt(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
}

class _CaptureButton extends StatelessWidget {
  const _CaptureButton({required this.scanning, required this.onFinish});
  final bool scanning;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          scanning ? 'Move slowly to cover every surface' : 'Starting…',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: Insets.s),
        GestureDetector(
          onTap: scanning ? onFinish : null,
          child: Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              border: Border.all(color: const Color(0xFF4CC2FF), width: 4),
            ),
            child: const Icon(Icons.check, size: 34, color: Colors.black),
          ),
        ),
      ],
    );
  }
}

class _FinishingIndicator extends StatelessWidget {
  const _FinishingIndicator();
  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(),
        SizedBox(height: Insets.s),
        Text('Reconstructing mesh…', style: TextStyle(color: Colors.white70)),
      ],
    );
  }
}

class _ArSurfacePlaceholder extends StatelessWidget {
  const _ArSurfacePlaceholder();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A0C10),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.camera_rear, color: Colors.white24, size: 48),
            SizedBox(height: 12),
            Text('AR depth view\n(native plugin surface)',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white24, height: 1.4)),
          ],
        ),
      ),
    );
  }
}
