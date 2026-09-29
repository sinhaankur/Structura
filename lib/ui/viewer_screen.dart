import 'package:flutter/material.dart';

import '../ar/ar_service.dart';
import '../export/export_service.dart';
import '../export/exporters.dart';
import '../mesh/dedrift.dart';
import '../mesh/scan_processor.dart';
import '../model/scan.dart';
import 'mesh_view.dart';
import 'theme.dart';

/// Post-capture: view the scan, read its measured dimensions, optimize it against
/// a triangle budget, and export/share/save. The 3D viewport itself is a GL
/// widget (mesh_view.dart); this screen is the surrounding controls.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.scan});
  final Scan scan;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  late Scan _scan = widget.scan;
  final _export = ExportService();
  final _ar = ArService();
  bool _busy = false;
  ShadeMode _mode = ShadeMode.solid;

  /// De-drift analysis of the current mesh — non-null when duplication is worth
  /// offering to fix (the "two toilets" case). Recomputed after any mesh change.
  late DriftReport _drift = DeDrift.analyze(_scan.mesh);

  @override
  Widget build(BuildContext context) {
    final m = _scan.mesh;
    final dims = m.dimensions();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _showExportSheet,
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export / Share',
          ),
        ],
      ),
      body: Column(
        children: [
          // 3D viewport — interactive software-rendered mesh (orbit/pan/zoom),
          // with a shade-mode selector overlaid top-right.
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    margin: const EdgeInsets.all(Insets.m),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: MeshView(scan: _scan, mode: _mode),
                  ),
                ),
                Positioned(
                  top: Insets.l,
                  right: Insets.l,
                  child: _ModeSelector(
                    mode: _mode,
                    onChanged: (m) => setState(() => _mode = m),
                  ),
                ),
              ],
            ),
          ),
          // stats + honest quality label
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.m),
            child: Row(
              children: [
                _Stat(label: 'Quality', value: _scan.quality.label),
                _Stat(label: 'Triangles', value: _fmt(m.triangleCount)),
                _Stat(
                    label: 'Size',
                    value:
                        '${dims.x.toStringAsFixed(2)}×${dims.y.toStringAsFixed(2)}×${dims.z.toStringAsFixed(2)} m'),
              ],
            ),
          ),
          const SizedBox(height: Insets.m),
          // De-drift banner — only when the scan looks duplicated (the "two
          // toilets" case). Honest: says what it found and what a fix would do.
          if (_drift.doubled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.m),
              child: Container(
                padding: const EdgeInsets.all(Insets.s),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.orangeAccent.withOpacity(0.4)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.content_copy, size: 18, color: Colors.orangeAccent),
                    const SizedBox(width: Insets.s),
                    Expanded(
                      child: Text(_drift.summary,
                          style: const TextStyle(fontSize: 12, height: 1.3)),
                    ),
                    const SizedBox(width: Insets.s),
                    TextButton(
                      onPressed: _busy ? null : _fixDoubling,
                      child: const Text('Merge'),
                    ),
                  ],
                ),
              ),
            ),
          if (_drift.doubled) const SizedBox(height: Insets.m),
          // View in AR — place/walk the scan at real scale (iOS AR Quick Look).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.m),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _viewInAR,
                icon: const Icon(Icons.view_in_ar),
                label: const Text('View in AR — real scale'),
              ),
            ),
          ),
          const SizedBox(height: Insets.m),
          // optimize controls
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.m),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _autoClean,
                    icon: const Icon(Icons.auto_fix_high),
                    label: const Text('Optimize'),
                  ),
                ),
                const SizedBox(width: Insets.s),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _showExportSheet,
                    icon: const Icon(Icons.share),
                    label: const Text('Export'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Insets.l),
        ],
      ),
    );
  }

  Future<void> _autoClean() async {
    setState(() => _busy = true);
    // Runs the same pipeline as the post-capture pass, on a background isolate
    // (ScanProcessor.reclean → compute()), so a big mesh never janks the UI.
    final cleaned =
        await ScanProcessor.reclean(_scan.mesh, triangleBudget: 150000);
    if (!mounted) return;
    setState(() {
      _scan.mesh = cleaned;
      _drift = DeDrift.analyze(cleaned);
      _busy = false;
    });
    _toast('Optimized to ${_fmt(cleaned.triangleCount)} triangles');
  }

  /// Merge drift-doubled geometry (the "two toilets" fix). Fuses the overlapping
  /// copies into one surface, then re-analyzes so the banner clears when resolved.
  Future<void> _fixDoubling() async {
    setState(() => _busy = true);
    final before = _scan.mesh.vertexCount;
    final merged = DeDrift.merge(_scan.mesh);
    if (!mounted) return;
    setState(() {
      _scan.mesh = merged;
      _drift = DeDrift.analyze(merged);
      _busy = false;
    });
    _toast('Merged duplicates: ${_fmt(before)} → ${_fmt(merged.vertexCount)} vertices');
  }

  /// Place/walk the scan at real scale via AR Quick Look. Honest failure messages
  /// (no AR support, USDZ export failed) rather than a silent no-op.
  Future<void> _viewInAR() async {
    setState(() => _busy = true);
    try {
      if (!await _ar.isSupported()) {
        _toast('AR isn’t available on this device');
        return;
      }
      await _ar.viewInAR(_scan);
    } on ArException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showExportSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF14171F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: Insets.s),
            const Text('Export to…',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: Insets.s),
            for (final f in ExportService.offered)
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(f.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(ctx);
                  _doExport(f);
                },
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Save render to Photos'),
              subtitle: const Text('Saves a snapshot of the 3D view'),
              onTap: () {
                Navigator.pop(ctx);
                _saveToPhotos();
              },
            ),
            const SizedBox(height: Insets.s),
          ],
        ),
      ),
    );
  }

  Future<void> _doExport(ExportFormat f) async {
    setState(() => _busy = true);
    try {
      await _export.shareToTools(_scan, f);
    } catch (e) {
      _toast('Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveToPhotos() async {
    setState(() => _busy = true);
    try {
      final png = await renderScanToPng(_scan);
      await _export.saveRenderToPhotos(png);
      _toast('Saved render to Photos');
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  static String _fmt(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 2),
          Text(value,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// A compact vertical toggle for the four shade modes, floated over the viewport.
class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.mode, required this.onChanged});
  final ShadeMode mode;
  final ValueChanged<ShadeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.all(4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in ShadeMode.values)
            Tooltip(
              message: m.label,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                color: m == mode ? const Color(0xFF4CC2FF) : Colors.white54,
                onPressed: () => onChanged(m),
                icon: Icon(m.icon),
              ),
            ),
        ],
      ),
    );
  }
}
