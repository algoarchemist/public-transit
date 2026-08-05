# SetuTrack

Real-time public transport tracking for small Punjab cities — SIH 2025, Problem
Statement 25013. Full architecture, dataset/model strategy, and build order are in
[`SIH25013_TrackMyRide_Solution.md`](./SIH25013_TrackMyRide_Solution.md); this README
covers just the repo layout and how to run what's here.

## Layout

```
apps/
  passenger-app/     Flutter — commuter live map, ETA, ticketing, voice assistant
  driver-app/        Flutter — driver/conductor trip control, GPS streaming, ticket validation
  admin-dashboard/   React + TS + Vite + Tailwind — fleet map, analytics, planning views
services/
  api-gateway/       NestJS — routes/stops, buses (REST fallback), tickets, auth
  ml-service/        FastAPI — ETA and crowd-prediction inference (ONNX, naive baseline until trained)
  stream-processor/  Node/TS — MQTT ingestion, map-matching, ETA scoring, Kafka + Socket.IO fan-out
packages/
  shared-types/      TypeScript types shared between admin-dashboard and stream-processor
infra/
  docker/, k8s/      placeholders for deployment manifests
docker-compose.yml   local dev infra: Postgres/PostGIS, Redis, Redpanda (Kafka API), EMQX (MQTT)
```

This is an npm workspace at the root (`apps/admin-dashboard`, `services/api-gateway`,
`services/stream-processor`, `packages/shared-types`) — the Flutter apps and the
Python `ml-service` are outside the npm workspace and managed with their own
toolchains.

## Running it locally

1. **Infra**: `docker compose up -d` — brings up Postgres/PostGIS, Redis, Redpanda, EMQX.
2. **JS/TS services** (from repo root, installs all workspaces at once):
   ```
   npm install
   npm run --workspace services/api-gateway start:dev
   npm run --workspace services/stream-processor dev:consumer
   npm run --workspace services/stream-processor dev:gateway
   npm run --workspace apps/admin-dashboard dev
   ```
   Copy each service's `.env.example` to `.env` first.
3. **ml-service**:
   ```
   cd services/ml-service
   python -m venv .venv && source .venv/Scripts/activate  # or .venv/bin/activate on macOS/Linux
   pip install -r requirements.txt
   uvicorn app.main:app --reload
   ```
4. **passenger-app / driver-app**: need the Flutter SDK, which wasn't available when
   this repo was scaffolded — see each app's README for the one-time `flutter create .`
   step needed to generate the `android/`/`ios/`/`web/` platform folders.

## Status

Everything above is a scaffold: folder structure, typed stubs, and TODOs marking
where the real map-matching, ML models, payment integration, and live UI need to be
built in, following the build order in section 6 of the solution doc.
