import 'package:flutter/material.dart';

/// A flat, side-profile coach illustration in Punjab state-transport livery
/// (PRTC/PUNBUS's white body, blue window band, orange belt stripe) — same "here
/// is the actual vehicle" role the reference designs give a bus photo on the
/// start-time screens, built from plain widget composition (Containers/ClipRRect)
/// like the rest of `lib/ui/`, rather than a sourced image, so it themes correctly
/// and needs no shipped asset.
class PunjabBusIllustration extends StatelessWidget {
  const PunjabBusIllustration({super.key, this.width = 132, this.height = 76});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final bodyH = height * 0.62;
    final wheelD = height * 0.34;

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomCenter,
        children: [
          // Body shadow, grounding the illustration on the card.
          Positioned(
            bottom: 0,
            child: Container(
              width: width * 0.88,
              height: 6,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
          Positioned(
            bottom: wheelD * 0.5,
            child: Container(
              width: width,
              height: bodyH,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFFFFFFF), Color(0xFFEFF3F9)],
                ),
                borderRadius: BorderRadius.circular(bodyH * 0.22),
                border: Border.all(color: const Color(0xFFD3DCEA), width: 1.2),
                boxShadow: const [BoxShadow(color: Color(0x1A0F1E38), blurRadius: 8, offset: Offset(0, 3))],
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: width * 0.045, vertical: bodyH * 0.1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Roof strip — deep transport blue.
                    Container(
                      height: bodyH * 0.1,
                      decoration: BoxDecoration(
                        color: const Color(0xFF16337A),
                        borderRadius: BorderRadius.circular(bodyH * 0.05),
                      ),
                    ),
                    SizedBox(height: bodyH * 0.06),
                    // Window band: rear windows + a taller slanted windscreen at front.
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Row(
                              children: List.generate(3, (i) {
                                return Expanded(
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(horizontal: width * 0.01),
                                    child: _Window(),
                                  ),
                                );
                              }),
                            ),
                          ),
                          SizedBox(width: width * 0.02),
                          Expanded(
                            flex: 2,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(bodyH * 0.08),
                              child: Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [Color(0xFF4A7DF0), Color(0xFF16337A)],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: bodyH * 0.07),
                    // Orange belt stripe with a small state-transport wordmark.
                    Container(
                      height: bodyH * 0.16,
                      alignment: Alignment.centerLeft,
                      padding: EdgeInsets.symmetric(horizontal: width * 0.03),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8832B),
                        borderRadius: BorderRadius.circular(bodyH * 0.04),
                      ),
                      child: Text(
                        'PUNJAB ROADWAYS',
                        style: TextStyle(
                          fontSize: (bodyH * 0.1).clamp(6.5, 9.5),
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Front bumper accent + headlight, right-hand end reads as the "front".
          Positioned(
            bottom: wheelD * 0.5,
            right: -width * 0.01,
            child: Container(
              width: width * 0.045,
              height: bodyH * 0.5,
              decoration: BoxDecoration(
                color: const Color(0xFFFFC94A),
                borderRadius: BorderRadius.circular(width * 0.02),
              ),
            ),
          ),
          // Wheels.
          Positioned(bottom: 0, left: width * 0.18, child: _Wheel(diameter: wheelD)),
          Positioned(bottom: 0, right: width * 0.18, child: _Wheel(diameter: wheelD)),
        ],
      ),
    );
  }
}

class _Window extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF6E97F5), Color(0xFF16337A)],
          ),
        ),
      ),
    );
  }
}

class _Wheel extends StatelessWidget {
  const _Wheel({required this.diameter});
  final double diameter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: const Color(0xFF1B2130),
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFF0B0E15), width: 1.4),
      ),
      child: Center(
        child: Container(
          width: diameter * 0.42,
          height: diameter * 0.42,
          decoration: const BoxDecoration(color: Color(0xFF9AA1AC), shape: BoxShape.circle),
        ),
      ),
    );
  }
}
