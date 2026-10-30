/// The station-review outcome, ported from the prototype's screen 7.
///
/// The prototype simulates a stitch and then shows one of two outcomes:
/// * outcome **A** — the panorama is ready; or
/// * outcome **B** — "coverage needs review", and frames 3 and 11 (0-based)
///   are flagged as needing a retake (the [badFrameIndices] the review grid
///   draws in amber).
///
/// The real flow derives "needs review" from measured coverage and the
/// pre-stitch gate, which is the honest version of the prototype's simulation.
/// When it does need review, the same two frames are the ones the user is sent
/// back to — so the review grid and the "retake affected frames" button line up
/// with the prototype.
enum ReviewOutcomeKind {
  /// Outcome A: the panorama is ready to accept.
  ready,

  /// Outcome B: coverage needs review; some frames need a retake.
  needsReview,
}

/// The result of reviewing a station.
class ReviewOutcome {
  final ReviewOutcomeKind kind;

  /// 0-based frame indices the review flags for a retake. Empty for [ready].
  final List<int> badFrameIndices;

  const ReviewOutcome({
    required this.kind,
    this.badFrameIndices = const <int>[],
  });

  bool get ready => kind == ReviewOutcomeKind.ready;

  bool isBad(int frameIndex) => badFrameIndices.contains(frameIndex);
}

/// Builds the review outcome.
///
/// [needsReview] is whatever the real flow concluded (coverage / pre-stitch
/// gate). When true, frames 3 and 11 are reported bad, matching the prototype's
/// screen-7 behaviour exactly.
ReviewOutcome reviewOutcome({required bool needsReview}) => needsReview
    ? const ReviewOutcome(
        kind: ReviewOutcomeKind.needsReview,
        badFrameIndices: <int>[3, 11],
      )
    : const ReviewOutcome(kind: ReviewOutcomeKind.ready);

/// Convenience: the outcome for a [StationRecord]-style status list.
///
/// Mirrors the prototype: [StationOutcome.needsReview] → bad frames [3, 11];
/// otherwise ready.
ReviewOutcome reviewOutcomeFromStatuses(
  List<int> badFrameIndicesWhenNeedsReview,
) => ReviewOutcome(
  kind: ReviewOutcomeKind.needsReview,
  badFrameIndices: badFrameIndicesWhenNeedsReview,
);
