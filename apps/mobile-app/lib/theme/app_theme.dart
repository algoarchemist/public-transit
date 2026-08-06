import 'package:flutter/material.dart';

/// SetuTrack's visual system: premium, minimal, iOS-inspired.
///
/// The rules this encodes, in one place so no screen has to re-derive them:
/// a very light cool-toned background, content living in large rounded white
/// cards separated by tone and a whisper of shadow rather than by borders or
/// dividers, one soft blue accent carrying all interactivity, and everything else
/// held to white / off-white / pale blue / charcoal / muted grey.
///
/// Material's own defaults fight this look — ripples, heavy elevation, 4px radii,
/// tinted surfaces — so they are switched off here rather than overridden per
/// widget. Build screens from `lib/ui/components.dart`, not from raw Material
/// widgets, and the language stays consistent for free.
class AppTheme {
  // --- Palette --------------------------------------------------------------

  /// Soft blue. The only saturated colour in the app: buttons, selected states,
  /// active icons, indicators. If something is tappable or currently chosen, it
  /// is this colour; if it is not, it is grey. That is the whole colour logic.
  static const primary = Color(0xFF4A7DF0);
  static const primaryPressed = Color(0xFF3C6BD8);

  /// Pale blue wash for nested/secondary containers and selected-but-quiet chips.
  static const primaryWash = Color(0xFFEAF0FE);

  /// Icy blue-grey page background. Cool enough that a pure-white card visibly
  /// lifts off it without needing a border.
  static const bgLight = Color(0xFFEFF3F9);
  static const cardLight = Color(0xFFFFFFFF);

  /// Extremely light blue-grey, for cards nested inside cards where pure white on
  /// white would lose the boundary.
  static const cardNestedLight = Color(0xFFF6F8FC);
  static const borderLight = Color(0xFFE4EAF3);

  static const textLight = Color(0xFF121826); // charcoal, not black
  static const textMutedLight = Color(0xFF7B8798);

  // Dark theme: the same composition, re-lit. Deep blue-charcoal rather than
  // neutral black keeps the cool cast, so the blue accent still reads as calm.
  static const bgDark = Color(0xFF0D1117);
  static const cardDark = Color(0xFF171D27);
  static const cardNestedDark = Color(0xFF1E2531);
  static const borderDark = Color(0xFF262E3B);
  static const primaryDark = Color(0xFF7BA4FF);
  static const primaryWashDark = Color(0xFF1B2436);
  static const textDark = Color(0xFFEDF1F7);
  static const textMutedDark = Color(0xFF8D99AB);

  /// Confidence tiers (docs §7.4) and occupancy bands. Desaturated to sit inside
  /// the restrained palette — these are status *metadata*, and must never out-shout
  /// the blue that marks what you can actually tap.
  static const liveGreen = Color(0xFF2FA36B);
  static const estimatedAmber = Color(0xFFD99A2B);
  static const staleGrey = Color(0xFF8D99AB);
  static const seatsFree = Color(0xFF2FA36B);
  static const standingRoom = Color(0xFFD99A2B);
  static const crowded = Color(0xFFDD6B5C);

  // --- Geometry & depth -----------------------------------------------------

  static const radiusCard = 24.0;
  static const radiusNested = 18.0;
  static const radiusField = 18.0;
  static const radiusPill = 999.0;

  /// Screen gutter. Everything full-width sits inside this.
  static const screenPadding = 20.0;
  static const gap = 14.0;
  static const gapSection = 24.0;

  /// Barely-there lift. Two stacked shadows — a wide soft one for the ambient
  /// float and a tight one for the contact edge — reads far cleaner than a single
  /// heavy blur, which is what makes Material cards look dated.
  static List<BoxShadow> cardShadow(bool isDark) => isDark
      ? const [BoxShadow(color: Color(0x33000000), blurRadius: 20, offset: Offset(0, 8))]
      : const [
          BoxShadow(color: Color(0x0A1B3B6B), blurRadius: 28, offset: Offset(0, 10)),
          BoxShadow(color: Color(0x080F1E38), blurRadius: 6, offset: Offset(0, 2)),
        ];

  /// SF Pro on Apple platforms, Segoe UI on Windows (what the Chrome preview
  /// runs), Inter/Roboto elsewhere. A stack rather than a bundled webfont: it
  /// costs no download, cannot fail offline at a demo, and each platform's own
  /// UI face is exactly the look being asked for.
  static const _fontFallback = ['SF Pro Text', '-apple-system', 'Inter', 'Segoe UI', 'Roboto'];

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    final scheme = ColorScheme(
      brightness: brightness,
      primary: isDark ? primaryDark : primary,
      onPrimary: isDark ? const Color(0xFF0B1220) : Colors.white,
      primaryContainer: isDark ? primaryWashDark : primaryWash,
      onPrimaryContainer: isDark ? primaryDark : primaryPressed,
      secondary: isDark ? primaryDark : primary,
      onSecondary: isDark ? const Color(0xFF0B1220) : Colors.white,
      surface: isDark ? cardDark : cardLight,
      onSurface: isDark ? textDark : textLight,
      surfaceContainerHighest: isDark ? cardNestedDark : cardNestedLight,
      onSurfaceVariant: isDark ? textMutedDark : textMutedLight,
      outline: isDark ? borderDark : borderLight,
      outlineVariant: isDark ? borderDark : borderLight,
      error: crowded,
      onError: Colors.white,
    );

    final text = _textTheme(isDark);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? bgDark : bgLight,
      canvasColor: isDark ? bgDark : bgLight,
      fontFamilyFallback: _fontFallback,
      textTheme: text,
      primaryTextTheme: text,

      // Material's tap ripple is the single most Material-looking thing on screen.
      // Components in lib/ui/ use a subtle opacity/scale press instead.
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,

      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: isDark ? bgDark : bgLight,
        surfaceTintColor: Colors.transparent,
        foregroundColor: isDark ? textDark : textLight,
        titleTextStyle: text.titleLarge,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: isDark ? cardDark : cardLight,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusCard)),
      ),
      // Fields are filled shapes with no visible outline until focused — an
      // outlined box at rest reads as a form, which is the opposite of airy.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? cardNestedDark : cardNestedLight,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        hintStyle: text.bodyMedium?.copyWith(color: isDark ? textMutedDark : textMutedLight),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusField),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusField),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusField),
          borderSide: BorderSide(color: isDark ? primaryDark : primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusField),
          borderSide: const BorderSide(color: crowded, width: 1.4),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusField),
          borderSide: const BorderSide(color: crowded, width: 1.6),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? borderDark : borderLight,
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? cardDark : cardLight,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? cardDark : cardLight,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusCard)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? cardNestedDark : const Color(0xFF1B2434),
        contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusNested)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: isDark ? primaryDark : primary,
        strokeWidth: 2.4,
      ),
      iconTheme: IconThemeData(color: isDark ? textDark : textLight, size: 22),
    );
  }

  /// Compact, tightly-tracked, with a strong weight jump between levels. The
  /// hierarchy is carried by weight and colour rather than by size alone, which is
  /// what keeps dense transit data (route numbers, ETAs, distances) legible
  /// without the layout getting loud.
  static TextTheme _textTheme(bool isDark) {
    final onSurface = isDark ? textDark : textLight;
    final muted = isDark ? textMutedDark : textMutedLight;

    return TextTheme(
      // Page titles
      headlineLarge: TextStyle(
          fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -0.6, height: 1.2, color: onSurface),
      headlineMedium: TextStyle(
          fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.4, height: 1.2, color: onSurface),
      // Big values — an ETA, a passenger count
      displaySmall: TextStyle(
          fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -0.8, height: 1.1, color: onSurface),
      titleLarge: TextStyle(
          fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.3, height: 1.25, color: onSurface),
      titleMedium: TextStyle(
          fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: -0.2, height: 1.3, color: onSurface),
      // Section headers above cards
      titleSmall: TextStyle(
          fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.2, height: 1.3, color: muted),
      bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, height: 1.4, color: onSurface),
      bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.4, color: onSurface),
      // Metadata: distances, timestamps, freshness
      bodySmall: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, height: 1.35, color: muted),
      labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.1, color: onSurface),
      labelMedium: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: muted),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.3, color: muted),
    );
  }

  // --- Semantic helpers -----------------------------------------------------

  /// Maps a `bus:update.confidenceTier` straight to its colour, so the map marker,
  /// the ETA row and the bus list can never disagree about what "live" looks like.
  static Color tierColor(String? tier) => switch (tier) {
        'live' => liveGreen,
        'estimated' => estimatedAmber,
        _ => staleGrey,
      };

  static Color occupancyColor(int? occupancy, {int capacity = 50}) {
    if (occupancy == null) return staleGrey;
    final ratio = occupancy / capacity;
    if (ratio < 0.6) return seatsFree;
    if (ratio < 0.9) return standingRoom;
    return crowded;
  }

  static String occupancyLabel(int? occupancy, {int capacity = 50}) {
    if (occupancy == null) return 'Unknown';
    final ratio = occupancy / capacity;
    if (ratio < 0.6) return 'Seats free';
    if (ratio < 0.9) return 'Standing';
    return 'Crowded';
  }
}
