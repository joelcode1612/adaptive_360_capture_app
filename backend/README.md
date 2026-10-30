# SiteSense capture ingestion API

This backend accepts the numbered AR photographs before panorama stitching.
It deliberately stops at a durable stitch manifest: a worker can consume that
manifest later without re-reading the mobile app or database.

## Run locally

```powershell
cd backend
Copy-Item .env.example .env
uv sync --group dev
$env:SITESENSE_ALLOW_DEVELOPMENT_IDENTITY = 'true'
uv run uvicorn sitesense.main:app --app-dir src --reload
```

In development, send a UUID in `X-User-Id`. Production must replace that
development-only identity dependency with verified JWT authentication.

## Capture protocol

1. `POST /api/v1/virtual-tours` with `property_id` and `expected_capture_count`.
2. For each target, `POST /api/v1/virtual-tours/{tour_id}/captures` as
   `multipart/form-data` with `target_index`, `captured_at`, `pose_json`, and
   `image`. A repeated identical target upload is idempotent; a different file
   for the same target is rejected.
3. `POST /api/v1/virtual-tours/{tour_id}/finalise` once all captures are present.
   It creates `tours/{tour_id}/stitch-manifest-*.json` and marks the tour
   `stitch_pending` for a later worker.

The image bytes, dimensions, content type, SHA-256, AR pose, and capture time
are retained in the manifest so a stitcher can order and align the inputs.
