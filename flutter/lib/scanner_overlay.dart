/// Viewfinder overlay: corner brackets, animated scan line + "Analyzing
/// label…" while scanning, status text, and a flash toggle. Stack it over
/// your CameraPreview. Every element is configurable; `visible: false`
/// renders nothing.
library scanner_overlay;

import 'package:flutter/material.dart';

class ScannerOverlay extends StatefulWidget {
  /// Master switch — false renders nothing.
  final bool visible;

  /// Corner-bracket framing box.
  final bool brackets;

  /// True while a scan is in flight: shows the animated line + [analyzingText].
  final bool analyzing;
  final String analyzingText;

  /// Guidance line ("Hold steady…") — ignored while analyzing.
  final String status;

  /// Flash button (default shown; hide with false). Wire to
  /// `cameraController.setFlashMode(FlashMode.torch / FlashMode.off)`.
  final bool showFlash;
  final bool flashOn;
  final VoidCallback? onToggleFlash;

  const ScannerOverlay({
    super.key,
    this.visible = true,
    this.brackets = true,
    this.analyzing = false,
    this.analyzingText = 'Analyzing label…',
    this.status = '',
    this.showFlash = true,
    this.flashOn = false,
    this.onToggleFlash,
  });

  @override
  State<ScannerOverlay> createState() => _ScannerOverlayState();
}

class _ScannerOverlayState extends State<ScannerOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  @override
  void didUpdateWidget(ScannerOverlay old) {
    super.didUpdateWidget(old);
    if (widget.analyzing && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.analyzing) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();
    final text = widget.analyzing ? widget.analyzingText : widget.status;

    return IgnorePointer(
      ignoring: false,
      child: LayoutBuilder(builder: (context, constraints) {
        final h = constraints.maxHeight;
        return Stack(children: [
          if (widget.brackets)
            const Positioned.fill(child: CustomPaint(painter: _BracketPainter())),
          if (widget.analyzing)
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => Positioned(
                left: constraints.maxWidth * 0.08,
                right: constraints.maxWidth * 0.08,
                top: h * 0.08 + (h * 0.82) * _controller.value,
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.95),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.7),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (text.isNotEmpty)
            Positioned(
              bottom: h * 0.04,
              left: 16,
              right: 16,
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                ),
              ),
            ),
          if (widget.showFlash && widget.onToggleFlash != null)
            Positioned(
              top: 10,
              right: 10,
              child: Material(
                color: Colors.black,
                shape: const CircleBorder(),
                child: IconButton(
                  icon: Icon(
                    Icons.bolt,
                    color: widget.flashOn
                        ? const Color(0xFFFFD60A)
                        : Colors.white,
                    size: 22,
                  ),
                  onPressed: widget.onToggleFlash,
                  tooltip: 'Toggle flash',
                ),
              ),
            ),
        ]);
      }),
    );
  }
}

class _BracketPainter extends CustomPainter {
  const _BracketPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.92)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final inset = Offset(size.width * 0.06, size.height * 0.06);
    final arm = size.shortestSide * 0.09;

    void corner(Offset origin, double dx, double dy) {
      canvas.drawLine(origin, origin + Offset(arm * dx, 0), paint);
      canvas.drawLine(origin, origin + Offset(0, arm * dy), paint);
    }

    corner(inset, 1, 1); // top-left
    corner(Offset(size.width - inset.dx, inset.dy), -1, 1); // top-right
    corner(Offset(inset.dx, size.height - inset.dy), 1, -1); // bottom-left
    corner(Offset(size.width - inset.dx, size.height - inset.dy), -1, -1);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
