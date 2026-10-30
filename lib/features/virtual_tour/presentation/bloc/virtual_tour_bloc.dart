import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/models/virtual_tour.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/repositories/virtual_tour_repository.dart';

/// REQ-807 / REQ-808: the upload workflow as an explicit state machine.
///
/// Four states, and no fifth "uploading in the background" state: the screen can
/// always tell whether work is running, whether it finished and what came back,
/// or why it did not.
sealed class VirtualTourState {
  const VirtualTourState();
}

/// Nothing has been requested yet.
class VirtualTourInitial extends VirtualTourState {
  final String? message;

  const VirtualTourInitial({this.message});
}

/// Work is in flight. [stage] names the half that is running and [message] is a
/// full sentence for the overlay.
class VirtualTourProcessing extends VirtualTourState {
  final VirtualTourStage stage;
  final String message;

  /// How many photographs the request carries. Shown as a number rather than a
  /// fake percentage: HTTP gives no per-part progress through `package:http`.
  final int imageCount;

  const VirtualTourProcessing({
    required this.stage,
    required this.message,
    this.imageCount = 0,
  });
}

/// The stitcher returned a panorama, and optionally the verification
/// acknowledgement.
class VirtualTourSuccess extends VirtualTourState {
  final StitchedPanorama panorama;

  /// Non-null once [VirtualTourVerificationRequested] succeeded.
  final VirtualTourSubmission? submission;

  const VirtualTourSuccess({required this.panorama, this.submission});

  bool get submitted => submission != null;
}

/// Everything failed with a message the user can act on.
class VirtualTourError extends VirtualTourState {
  final String message;
  final VirtualTourStage stage;
  final bool retryable;

  /// The panorama that already exists, when the failure was the submit step.
  /// Keeping it here is what lets the success panel remain truthful while the
  /// retry runs, instead of dropping the stitched result on the floor.
  final StitchedPanorama? panorama;

  const VirtualTourError({
    required this.message,
    required this.stage,
    required this.retryable,
    this.panorama,
  });
}

sealed class VirtualTourEvent {
  const VirtualTourEvent();
}

/// Upload the station's captures and stitch them.
class VirtualTourStitchRequested extends VirtualTourEvent {
  final String tourId;
  final String propertyId;
  final String stationId;
  final List<PanoramaImage> images;

  const VirtualTourStitchRequested({
    required this.tourId,
    required this.propertyId,
    required this.stationId,
    required this.images,
  });
}

/// Submit an already-stitched panorama for verification.
class VirtualTourVerificationRequested extends VirtualTourEvent {
  final String tourId;
  final List<StitchedPanorama> panoramas;

  const VirtualTourVerificationRequested({
    required this.tourId,
    required this.panoramas,
  });
}

/// Retry the last failed operation, with the same payload.
class VirtualTourRetryRequested extends VirtualTourEvent {
  const VirtualTourRetryRequested();
}

/// Drop every result and go back to [VirtualTourInitial].
class VirtualTourResetRequested extends VirtualTourEvent {
  const VirtualTourResetRequested();
}

/// The Bloc from the brief.
///
/// It owns three things the screen must not:
///
/// * **duplicate protection** — a second stitch while one is running, or a
///   second submit after one succeeded, is ignored rather than sent twice;
/// * **out-of-order protection** — every operation carries a token, and a
///   response that arrives after a reset or a newer operation is discarded;
/// * **retry** — only the last failed operation is retried, with its original
///   images, so "Try again" cannot accidentally submit a tour that was never
///   stitched.
class VirtualTourBloc extends Bloc<VirtualTourEvent, VirtualTourState> {
  VirtualTourBloc({
    required VirtualTourRepository repository,
    Duration stageDelay = const Duration(milliseconds: 500),
  }) : _repository = repository, // ignore: prefer_initializing_formals
       _stageDelay = stageDelay, // ignore: prefer_initializing_formals
       super(const VirtualTourInitial()) {
    on<VirtualTourStitchRequested>(_onStitch);
    on<VirtualTourVerificationRequested>(_onVerification);
    on<VirtualTourRetryRequested>(_onRetry);
    on<VirtualTourResetRequested>(_onReset);
  }

  final VirtualTourRepository _repository;

  /// How long the upload stage is shown before the overlay switches to
  /// "stitching". The remote call is one request, so this is the only honest
  /// boundary available; tests pass [Duration.zero].
  final Duration _stageDelay;

  /// Incremented by every new operation and by reset. A completion whose token
  /// no longer matches is stale and must not emit.
  int _operation = 0;

  /// The last operation that failed, for [VirtualTourRetryRequested].
  VirtualTourEvent? _lastFailed;

  Future<void> _onStitch(
    VirtualTourStitchRequested event,
    Emitter<VirtualTourState> emit,
  ) async {
    // Duplicate: work is already running, or the panorama already exists.
    if (state is VirtualTourProcessing || state is VirtualTourSuccess) return;
    await _runStitch(event, emit);
  }

  Future<void> _runStitch(
    VirtualTourStitchRequested event,
    Emitter<VirtualTourState> emit,
  ) async {
    if (event.images.isEmpty) {
      _lastFailed = null;
      emit(
        const VirtualTourError(
          message: 'There are no photographs to upload.',
          stage: VirtualTourStage.validation,
          retryable: false,
        ),
      );
      return;
    }

    final token = ++_operation;
    _lastFailed = null;
    emit(
      VirtualTourProcessing(
        stage: VirtualTourStage.uploading,
        message:
            'Uploading ${event.images.length} photographs to the stitching '
            'service…',
        imageCount: event.images.length,
      ),
    );

    // Start the request immediately, but attach the error handler *now*: a
    // repository that fails synchronously would otherwise complete before the
    // stage delay elapses and be reported as an unhandled async error.
    final Future<(StitchedPanorama?, Object?)> pending = _repository
        .uploadAndStitchPanorama(
          tourId: event.tourId,
          propertyId: event.propertyId,
          stationId: event.stationId,
          images: List<PanoramaImage>.unmodifiable(event.images),
        )
        .then<(StitchedPanorama?, Object?)>(
          (panorama) => (panorama, null),
          onError: (Object error) => (null, error),
        );

    // Let the first stage be readable. The request is already in flight, so
    // this adds no latency to the upload itself.
    await Future<void>.delayed(_stageDelay);
    if (!isClosed && token == _operation) {
      emit(
        VirtualTourProcessing(
          stage: VirtualTourStage.stitching,
          message:
              'Stitching ${event.images.length} photographs into an '
              'equirectangular panorama…',
          imageCount: event.images.length,
        ),
      );
    }

    final (panorama, error) = await pending;
    if (isClosed || token != _operation) return;
    if (panorama != null) {
      emit(VirtualTourSuccess(panorama: panorama));
      return;
    }
    _lastFailed = event;
    if (error is VirtualTourFailure) {
      emit(
        VirtualTourError(
          message: error.message,
          stage: VirtualTourStage.stitching,
          retryable: error.retryable,
        ),
      );
      return;
    }
    emit(
      VirtualTourError(
        message: 'The panorama could not be stitched: $error',
        stage: VirtualTourStage.stitching,
        retryable: true,
      ),
    );
  }

  Future<void> _onVerification(
    VirtualTourVerificationRequested event,
    Emitter<VirtualTourState> emit,
  ) async {
    if (state is VirtualTourProcessing) return;
    if (state is VirtualTourSuccess &&
        (state as VirtualTourSuccess).submitted) {
      return; // duplicate submit
    }
    await _runVerification(event, emit);
  }

  Future<void> _runVerification(
    VirtualTourVerificationRequested event,
    Emitter<VirtualTourState> emit,
  ) async {
    if (event.panoramas.isEmpty) {
      _lastFailed = null;
      emit(
        const VirtualTourError(
          message: 'There is no stitched panorama to submit.',
          stage: VirtualTourStage.validation,
          retryable: false,
        ),
      );
      return;
    }
    final panorama = event.panoramas.first;
    final token = ++_operation;
    _lastFailed = null;
    emit(
      const VirtualTourProcessing(
        stage: VirtualTourStage.submitting,
        message: 'Submitting the tour for verification…',
        imageCount: 1,
      ),
    );

    try {
      final submission = await _repository.submitVirtualTourForVerification(
        tourId: event.tourId,
        panoramas: List<StitchedPanorama>.unmodifiable(event.panoramas),
      );
      if (isClosed || token != _operation) return;
      emit(VirtualTourSuccess(panorama: panorama, submission: submission));
    } on VirtualTourFailure catch (failure, _) {
      if (isClosed || token != _operation) return;
      _lastFailed = event;
      emit(
        VirtualTourError(
          message: failure.message,
          stage: VirtualTourStage.submitting,
          retryable: failure.retryable,
          panorama: panorama,
        ),
      );
    } catch (e, _) {
      if (isClosed || token != _operation) return;
      _lastFailed = event;
      emit(
        VirtualTourError(
          message: 'The tour could not be submitted: $e',
          stage: VirtualTourStage.submitting,
          retryable: true,
          panorama: panorama,
        ),
      );
    }
  }

  Future<void> _onRetry(
    VirtualTourRetryRequested event,
    Emitter<VirtualTourState> emit,
  ) async {
    if (state is VirtualTourProcessing) return;
    final failed = _lastFailed;
    if (failed == null) return;
    _lastFailed = null;
    switch (failed) {
      case final VirtualTourStitchRequested stitch:
        await _runStitch(stitch, emit);
      case final VirtualTourVerificationRequested submit:
        await _runVerification(submit, emit);
      case final VirtualTourRetryRequested _:
      case final VirtualTourResetRequested _:
        return;
    }
  }

  void _onReset(
    VirtualTourResetRequested event,
    Emitter<VirtualTourState> emit,
  ) {
    _operation++;
    _lastFailed = null;
    emit(const VirtualTourInitial());
  }
}
