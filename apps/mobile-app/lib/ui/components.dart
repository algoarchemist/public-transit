import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The SetuTrack component kit.
///
/// Screens are assembled from these, not from raw Material widgets. That is what
/// keeps one visual language across two roles and a dozen screens: the 24px card
/// radius, the pill CTAs, the circular icon buttons, the barely-there shadows and
/// the spacing rhythm are decided once, here.
///
/// Layering model every screen follows:
///   background (pale, cool) -> large section card -> nested pale card -> content.
///
/// If you find yourself reaching for `Card`, `ElevatedButton`, `BottomNavigationBar`
/// or `OutlineInputBorder`, use the equivalent below instead — the Material
/// originals carry ripples, elevation tints and small radii that break the look.

// ---------------------------------------------------------------------------
// Scaffold & layout
// ---------------------------------------------------------------------------

/// Page shell: pale background, a large tracked title, and optional floating nav.
/// `bottomNav` floats above the content rather than being pinned edge-to-edge, so
/// content scrolls *under* it — hence the extra bottom padding.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.actions = const [],
    this.leading,
    this.bottomNav,
    this.padded = true,
    this.floatingAction,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? leading;
  final Widget? bottomNav;
  final bool padded;
  final Widget? floatingAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppTheme.screenPadding, 12, AppTheme.screenPadding, 4),
                    child: Row(
                      children: [
                        if (leading != null) ...[leading!, const SizedBox(width: 12)],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title!, style: theme.textTheme.headlineMedium),
                              if (subtitle != null) ...[
                                const SizedBox(height: 2),
                                Text(subtitle!, style: theme.textTheme.bodySmall),
                              ],
                            ],
                          ),
                        ),
                        ...actions,
                      ],
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: padded ? AppTheme.screenPadding : 0),
                    child: child,
                  ),
                ),
              ],
            ),
            if (bottomNav != null)
              Positioned(left: 0, right: 0, bottom: 0, child: SafeArea(top: false, child: bottomNav!)),
            if (floatingAction != null)
              Positioned(
                right: AppTheme.screenPadding,
                bottom: (bottomNav != null ? 96 : 24),
                child: floatingAction!,
              ),
          ],
        ),
      ),
    );
  }
}

/// Bottom padding that clears the floating nav bar, for the last item in a list.
class NavClearance extends StatelessWidget {
  const NavClearance({super.key, this.extra = 0});
  final double extra;

  @override
  Widget build(BuildContext context) => SizedBox(height: 108 + extra);
}

/// Small muted label above a group of cards. Section identity comes from this
/// plus whitespace — never from a divider or a heavy header bar.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.label, {super.key, this.trailing, this.padTop = true});

  final String label;
  final Widget? trailing;
  final bool padTop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: padTop ? AppTheme.gapSection : 0, bottom: 10, left: 4, right: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.titleSmall)),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

/// The primary container: white, 24px radius, lifted off the pale background by
/// tone plus a whisper of shadow. Tappable when [onTap] is given, with a restrained
/// scale press instead of a Material ripple.
class SoftCard extends StatefulWidget {
  const SoftCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(18),
    this.color,
    this.radius = AppTheme.radiusCard,
    this.showShadow = true,
    this.border,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double radius;
  final bool showShadow;
  final Border? border;

  @override
  State<SoftCard> createState() => _SoftCardState();
}

class _SoftCardState extends State<SoftCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final card = AnimatedScale(
      scale: _pressed ? 0.985 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: widget.padding,
        decoration: BoxDecoration(
          color: widget.color ?? (isDark ? AppTheme.cardDark : AppTheme.cardLight),
          borderRadius: BorderRadius.circular(widget.radius),
          border: widget.border,
          boxShadow: widget.showShadow ? AppTheme.cardShadow(isDark) : null,
        ),
        child: widget.child,
      ),
    );

    if (widget.onTap == null) return card;

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      behavior: HitTestBehavior.opaque,
      child: card,
    );
  }
}

/// A quieter container for controls and secondary detail *inside* a [SoftCard],
/// where white-on-white would lose the boundary. Pale blue-grey, no shadow.
class NestedCard extends StatelessWidget {
  const NestedCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SoftCard(
      onTap: onTap,
      padding: padding,
      radius: AppTheme.radiusNested,
      showShadow: false,
      color: color ?? (isDark ? AppTheme.cardNestedDark : AppTheme.cardNestedLight),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------

/// Wide pill CTA, filled soft blue. The one loud element on a screen — a page
/// should rarely have two.
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = true,
    this.color,
    this.foreground,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final bool expand;
  final Color? color;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = color ?? scheme.primary;
    final fg = foreground ?? scheme.onPrimary;
    final enabled = onPressed != null && !loading;

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          child: Container(
            width: expand ? double.infinity : null,
            height: 54,
            padding: EdgeInsets.symmetric(horizontal: expand ? 20 : 26),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (loading)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: fg),
                  )
                else if (icon != null) ...[
                  Icon(icon, size: 20, color: fg),
                  const SizedBox(width: 10),
                ],
                if (!loading)
                  Text(
                    label,
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: fg),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// White (or pale) pill for secondary actions — same geometry, no colour weight.
class SecondaryPillButton extends StatelessWidget {
  const SecondaryPillButton({super.key, required this.label, this.onPressed, this.icon, this.danger = false});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = danger ? AppTheme.crowded : Theme.of(context).colorScheme.onSurface;

    return Material(
      color: isDark ? AppTheme.cardNestedDark : Colors.white,
      borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        child: Container(
          height: 54,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusPill),
            border: Border.all(color: isDark ? AppTheme.borderDark : AppTheme.borderLight),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 10)],
              Text(label,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Standalone action in a soft circular container — back buttons, theme toggle,
/// map recentre, tally +/-.
class CircleIconButton extends StatelessWidget {
  const CircleIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.filled = false,
    this.size = 44,
    this.tooltip,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onPressed;

  /// Filled = blue background, white icon. Used for the emphasised action in a pair.
  final bool filled;
  final double size;
  final String? tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = color ?? scheme.primary;

    final button = Material(
      color: filled ? accent : (isDark ? AppTheme.cardNestedDark : Colors.white),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: filled
                ? null
                : Border.all(color: isDark ? AppTheme.borderDark : AppTheme.borderLight),
          ),
          child: Icon(
            icon,
            size: size * 0.45,
            color: filled ? scheme.onPrimary : (color ?? scheme.onSurface),
          ),
        ),
      ),
    );

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/// Large filled rounded field, no outline at rest. Pair with a leading thin-line
/// icon for search.
class SoftTextField extends StatelessWidget {
  const SoftTextField({
    super.key,
    this.controller,
    this.hint,
    this.icon,
    this.onChanged,
    this.onSubmitted,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.maxLength,
    this.suffix,
    this.autofocus = false,
    this.enabled = true,
    this.style,
  });

  final TextEditingController? controller;
  final String? hint;
  final IconData? icon;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final int? maxLength;
  final Widget? suffix;
  final bool autofocus;
  final bool enabled;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      maxLength: maxLength,
      autofocus: autofocus,
      enabled: enabled,
      style: style ?? Theme.of(context).textTheme.bodyLarge,
      decoration: InputDecoration(
        hintText: hint,
        counterText: '',
        prefixIcon: icon == null
            ? null
            : Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
        suffixIcon: suffix,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

/// Rounded container where the selected option becomes a blue pill and the rest
/// stay transparent. For 2–4 mutually exclusive options.
class SoftSegmentedControl<T> extends StatelessWidget {
  const SoftSegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.labelOf,
    this.iconOf,
  });

  final List<T> options;
  final T value;
  final ValueChanged<T> onChanged;
  final String Function(T)? labelOf;
  final IconData? Function(T)? iconOf;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardNestedDark : AppTheme.cardNestedLight,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      ),
      child: Row(
        children: options.map((option) {
          final selected = option == value;
          final icon = iconOf?.call(option);
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(option),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? scheme.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icon != null) ...[
                      Icon(icon,
                          size: 16,
                          color: selected ? scheme.onPrimary : scheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        labelOf?.call(option) ?? option.toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

class NavItem {
  const NavItem({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

/// Floating rounded bottom bar — detached from the screen edge, white, very subtle
/// shadow. The active destination is a filled blue circle; inactive icons stay
/// monochrome and unlabelled so the bar reads as a quiet control, not a toolbar.
class FloatingBottomNav extends StatelessWidget {
  const FloatingBottomNav({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
  });

  final List<NavItem> items;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppTheme.screenPadding, 0, AppTheme.screenPadding, 18),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        child: BackdropFilter(
          // A touch of blur so content scrolling underneath softens rather than
          // colliding with the bar — the iOS translucency cue, kept very light.
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            height: 68,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: (isDark ? AppTheme.cardDark : Colors.white).withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(AppTheme.radiusPill),
              border: Border.all(color: isDark ? AppTheme.borderDark : AppTheme.borderLight),
              boxShadow: AppTheme.cardShadow(isDark),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(items.length, (i) {
                final selected = i == index;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => onChanged(i),
                    behavior: HitTestBehavior.opaque,
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: selected ? scheme.primary : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          items[i].icon,
                          size: 22,
                          color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Status & metadata
// ---------------------------------------------------------------------------

/// Small badge: a coloured dot plus a short label on a tinted ground. For
/// confidence tier, occupancy band, trip state. Never large enough to compete
/// with the blue accent.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color, this.icon, this.compact = false});

  final String label;
  final Color color;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: compact ? 4 : 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: compact ? 11 : 13, color: color)
          else
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          SizedBox(width: compact ? 5 : 6),
          Text(
            label,
            style: TextStyle(
              fontSize: compact ? 11 : 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Route-number badge — the one place a bold blue block is right, because a route
/// number is the primary identifier a rider scans a list for.
class RouteBadge extends StatelessWidget {
  const RouteBadge({super.key, required this.label, this.large = false});

  final String label;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 14 : 10, vertical: large ? 10 : 7),
      constraints: BoxConstraints(minWidth: large ? 56 : 42),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(large ? 16 : 12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: large ? 18 : 14,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

/// Thin-line icon + muted text, for distances, timestamps, counts.
class MetaRow extends StatelessWidget {
  const MetaRow({super.key, required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c),
          ),
        ),
      ],
    );
  }
}

/// A stop sequence drawn as a dotted connector rail — used for a route's stop list
/// with per-stop ETAs on both sides of the app. Connector lines and whitespace do
/// the separating; there are no dividers.
class StopTimeline extends StatelessWidget {
  const StopTimeline({super.key, required this.stops, this.activeIndex});

  final List<StopTimelineEntry> stops;

  /// The stop the bus is currently heading to; earlier stops render as passed.
  final int? activeIndex;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return Column(
      children: List.generate(stops.length, (i) {
        final entry = stops[i];
        final passed = activeIndex != null && i < activeIndex!;
        final isActive = activeIndex == i;
        final isLast = i == stops.length - 1;
        final dotColor = passed
            ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
            : (isActive ? scheme.primary : scheme.onSurfaceVariant);

        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 22,
                child: Column(
                  children: [
                    const SizedBox(height: 4),
                    Container(
                      width: isActive ? 12 : 9,
                      height: isActive ? 12 : 9,
                      decoration: BoxDecoration(
                        color: isActive ? scheme.primary : Colors.transparent,
                        border: Border.all(color: dotColor, width: 2),
                        shape: BoxShape.circle,
                      ),
                    ),
                    if (!isLast)
                      Expanded(
                        child: Container(
                          width: 2,
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          decoration: BoxDecoration(
                            color: dotColor.withValues(alpha: 0.28),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: isLast ? 0 : 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: (isActive
                                      ? theme.textTheme.titleMedium
                                      : theme.textTheme.bodyMedium)
                                  ?.copyWith(
                                color: passed ? scheme.onSurfaceVariant : null,
                              ),
                            ),
                          ),
                          if (entry.trailing != null) ...[
                            const SizedBox(width: 8),
                            entry.trailing!,
                          ],
                        ],
                      ),
                      if (entry.subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(entry.subtitle!, style: theme.textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

class StopTimelineEntry {
  const StopTimelineEntry({required this.name, this.subtitle, this.trailing});
  final String name;
  final String? subtitle;
  final Widget? trailing;
}

// ---------------------------------------------------------------------------
// Async states
// ---------------------------------------------------------------------------

/// Loading, empty and error all render as the same calm centred card so a screen
/// never jumps between layouts as it resolves.
class StateCard extends StatelessWidget {
  const StateCard._({
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.spinner = false,
    this.tint,
  });

  factory StateCard.loading({String title = 'Loading', String? message}) =>
      StateCard._(icon: Icons.hourglass_empty_rounded, title: title, message: message, spinner: true);

  factory StateCard.empty({required String title, String? message, IconData icon = Icons.inbox_outlined, Widget? action}) =>
      StateCard._(icon: icon, title: title, message: message, action: action);

  factory StateCard.error({required String message, VoidCallback? onRetry, String title = 'Something went wrong'}) =>
      StateCard._(
        icon: Icons.wifi_tethering_off_rounded,
        title: title,
        message: message,
        tint: AppTheme.crowded,
        action: onRetry == null
            ? null
            : _RetryButton(onRetry: onRetry),
      );

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool spinner;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = tint ?? scheme.primary;

    return SoftCard(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: spinner
                ? Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4, color: accent),
                    ),
                  )
                : Icon(icon, color: accent, size: 24),
          ),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
          ],
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    );
  }
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) =>
      SecondaryPillButton(label: 'Try again', icon: Icons.refresh_rounded, onPressed: onRetry);
}

/// Placeholder block for content still loading inside an otherwise-drawn card.
class SkeletonBlock extends StatelessWidget {
  const SkeletonBlock({super.key, this.height = 14, this.width, this.radius = 8});

  final double height;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
