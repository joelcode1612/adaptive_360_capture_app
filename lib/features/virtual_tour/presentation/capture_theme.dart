import 'package:flutter/material.dart';

/// The palette from `360° Capture Prototype.html`, as Flutter constants.
///
/// The prototype's colours are named rather than inlined so that the
/// distinction it draws between states survives the port:
///
/// * [ok] — a target that passed validation. The prototype uses one green for
///   both the aligned marker and the completed frame cell.
/// * [warn] — something needs attention but is not a failure: a low-information
///   frame, a frame awaiting a retake, a paused capture.
/// * [danger] — a rejection.
///
/// **Every screen is dark, including the ones without a camera.**
/// `.phone{background:#0f1418;color:#fff}` is the app, and the `:root`
/// light/dark variables outside it are the document the phone sits in, not the
/// product. There is no theme switch and nothing follows the system.
abstract final class CaptureColors {
  /// The prototype's `OK` (`#4cc27f`).
  static const Color ok = Color(0xFF4CC27F);

  /// The prototype's `AM` (`#f2a93b`).
  static const Color warn = Color(0xFFF2A93B);

  /// Rejections. The prototype has no explicit red — it uses the amber — but a
  /// rejection and a warning are different things and the UI says so.
  static const Color danger = Color(0xFFE5534B);

  /// The prototype's accent for buttons (`#2f9e5b`).
  static const Color accent = Color(0xFF2F9E5B);

  /// The camera chrome background (`#0f1418`).
  static const Color cameraChrome = Color(0xFF0F1418);

  /// The viewfinder's own background — the prototype's `.cam{background:#222}`.
  ///
  /// Deliberately *not* [cameraChrome]. The two states have to be told apart:
  /// `#222` is a viewfinder that is up and waiting for pixels, and `#0f1418` is
  /// the chrome around it. When the feed cannot draw, it fills this grey and
  /// writes the reason on top, so "the camera is coming" never looks like the
  /// dead-black box that made the first device run unusable.
  static const Color viewfinder = Color(0xFF222222);

  /// Muted text on the dark chrome (`#aeb6bf`, the prototype's `.mu`).
  static const Color mutedOnDark = Color(0xFFAEB6BF);

  /// The prototype's `.orb` size, in logical pixels.
  static const double orbSize = 102;

  /// The prototype's aiming reticle size, in logical pixels.
  static const double reticleSize = 96;

  /// An empty segment bar — the prototype's `.rng i` / `.fr i` (`#39424b`).
  static const Color trackOnDark = Color(0xFF39424B);

  /// The header's right-hand slot — the prototype's `.hd span` (`#c3cad2`).
  static const Color headerMuted = Color(0xFFC3CAD2);

  /// A bullet line inside a dark screen — the prototype's `.li` (`#d4dae0`).
  static const Color bulletOnDark = Color(0xFFD4DAE0);

  /// The viewfinder's inset focus frame — `.frame`, `rgba(255,255,255,.6)`.
  static const Color viewfinderFrame = Color(0x99FFFFFF);

  /// A hairline border on the dark chrome — `.cd`, `.op`, `.on` unset
  /// (`rgba(255,255,255,.2)`).
  static const Color hairlineOnDark = Color(0x33FFFFFF);

  /// A hairline one step quieter — `.sl>div` (`rgba(255,255,255,.1)`).
  static const Color hairlineFaint = Color(0x1AFFFFFF);

  /// A chip outline — `.chs button` (`rgba(255,255,255,.25)`).
  static const Color hairlineChip = Color(0x40FFFFFF);

  /// A ghost button's border — `.bt.g` (`rgba(255,255,255,.35)`).
  static const Color ghostButtonBorder = Color(0x59FFFFFF);

  /// That border under `.bt:disabled{opacity:.45}` (0x59 × 0.45 ≈ 0x28). Material
  /// has no disabled outline colour of its own on `OutlinedButton.styleFrom`, so
  /// the scale is done here rather than left to the theme's grey.
  static const Color ghostButtonBorderDisabled = Color(0x28FFFFFF);

  /// A filled row or cell on the dark chrome — `.stp div` (`rgba(255,255,255,.06)`).
  static const Color cardOnDark = Color(0x0FFFFFFF);

  /// The `.dg` group behind a grid of cells (`rgba(255,255,255,.05)`).
  static const Color groupOnDark = Color(0x0DFFFFFF);

  /// The `.note` surface, one step brighter than [cardOnDark].
  static const Color noteOnDark = Color(0x12FFFFFF);

  /// The selected-card fill — `.on`, `rgba(76,194,127,.15)`.
  static const Color selectedFill = Color(0x264CC27F);

  /// A text-only action — `.lk` (`#7fd9a2`).
  static const Color linkOnDark = Color(0xFF7FD9A2);

  /// A sheet's surface, and the prototype's `.sht` (`#1a2025`).
  static const Color sheet = Color(0xFF1A2025);

  /// The scrim behind a sheet — `.shd` (`rgba(8,10,12,.78)`).
  static const Color scrim = Color(0xC7080A0C);

  /// The sphere map's disc fill and outline — `sph()`'s `rgba(255,255,255,.06)`
  /// over `rgba(255,255,255,.35)`.
  static const Color sphereFill = Color(0x0FFFFFFF);
  static const Color sphereOutline = Color(0x59FFFFFF);

  /// An un-fired target on the map — `sph()`'s pending stroke (`#9aa3ad`).
  static const Color pendingDot = Color(0xFF9AA3AD);

  /// The target cell grid's fill for an un-captured frame.
  static const Color frameCellEmpty = Color(0xFF39424B);

  /// A "simulated" / provisional badge.
  static const Color provisional = Color(0xFFF2A93B);

  /// A translucent white surface, as the prototype uses throughout.
  static Color surface(double opacity) =>
      Colors.white.withValues(alpha: opacity);

  /// The dark surface the camera chrome uses behind text.
  static Color chromeOverlay([double opacity = 0.8]) =>
      cameraChrome.withValues(alpha: opacity);
}

/// Shared sizing so the screens agree with each other.
abstract final class CaptureMetrics {
  /// The viewfinder is 4:3 in portrait, matching the sensor the FOV model
  /// assumes. Kept here so the capture screen and the preview widget cannot
  /// drift apart.
  static const double viewfinderAspect = 3 / 4;

  /// The frame-cell grid: 13 columns × 2 rows, as the prototype draws it.
  static const int frameGridColumns = 13;

  static const double cornerRadius = 14;
  static const double smallRadius = 10;

  /// `.hd` — a 52 dp header row with a 32 dp round button in it.
  static const double headerHeight = 52;
  static const double headerIconSize = 32;

  /// `.frame` — the focus border's inset and corner.
  static const double viewfinderInset = 10;
  static const double viewfinderRadius = 16;

  /// `.mm` — the mini progress map, and the `.bn` banner that stops short of it.
  static const double miniMapSize = 88;
  static const double miniMapRadius = 18;
  static const double bannerRightInset = 108;

  /// `.bt` — 13 dp of padding around a 15 px semibold label.
  static const double buttonHeight = 48;

  /// `.ip` — the instruction panel under the viewfinder.
  static const double instructionHeight = 128;
}

/// The theme for the capture screens, whose scaffold is transparent so an AR
/// session's own camera surface can show through behind the Flutter view.
ThemeData captureCameraTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: Colors.transparent,
  colorScheme: _darkScheme,
);

/// The app's one theme.
///
/// The prototype has no light variant inside the phone, so this takes no
/// [Brightness] and nothing asks the system. A viewfinder cannot be shown in a
/// light theme, and a settings screen that changes colour between stations is
/// not in the reference.
ThemeData captureAppTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: CaptureColors.cameraChrome,
  colorScheme: _darkScheme,
);

const ColorScheme _darkScheme = ColorScheme.dark(
  primary: CaptureColors.accent,
  onPrimary: Colors.white,
  secondary: CaptureColors.ok,
  onSecondary: Colors.white,
  error: CaptureColors.danger,
  surface: CaptureColors.cameraChrome,
  onSurface: Colors.white,
  surfaceContainerHighest: CaptureColors.cardOnDark,
  onSurfaceVariant: CaptureColors.mutedOnDark,
  outline: CaptureColors.mutedOnDark,
  outlineVariant: CaptureColors.hairlineOnDark,
);
