# SIH 2025 — Problem Statement 25013
## Real-Time Public Transport Tracking for Small Cities (Government of Punjab)
### Complete End-to-End Solution: "SetuTrack" — Smart Public Transport Ecosystem

**Theme:** Transportation & Logistics | **Category:** Mobile & Web Solutions | **Difficulty:** Medium

**Core mandate (as per official PS):** low-bandwidth-optimized live bus tracking + accurate ETA for small Punjab cities, where GPS coverage, network reliability, and driver tech-literacy are inconsistent. Every architectural decision below is filtered through that constraint first.

---

## 0. Solution Snapshot

Three apps, one backend, one data pipeline:

| App | Users | Core job |
|---|---|---|
| **Passenger App** (Android/iOS/PWA) | Commuters | Track bus, get ETA, book ticket, see crowding, ask AI/voice bot |
| **Driver/Conductor App** (Android, ruggedized UI) | PRTC/PUNBUS staff | Start/end trip, share GPS, validate tickets, manage load |
| **Admin Command Dashboard** (Web) | Transport Dept, District RTA | Fleet monitoring, analytics, route planning, demand-supply insights |

Backbone: GPS pings → MQTT broker → stream processor → ETA/crowd ML models → WebSocket fan-out → apps. Everything degrades gracefully to SMS/USSD-level bandwidth.

---

## 1. Tech Stack

### 1.1 Guiding principle
Small-city Punjab = intermittent 3G/patchy 4G, budget Android phones on driver side, cost-sensitive government hosting. So: **payload size and offline-first design matter more than framework trendiness.**

### 1.2 Stack table

| Layer | Choice | Why this over alternatives |
|---|---|---|
| Passenger app | **Flutter** (single codebase, Android+iOS) + **PWA** (React) fallback for feature phones/low-end devices | One team ships two platforms fast; PWA needs no app-store install, critical for low first-time-download friction in tier-3 towns |
| Driver/Conductor app | **Flutter**, minimal-UI mode, large touch targets, offline queue | Same codebase reuse; must run on ₹6-8k Android devices govt. will procure in bulk |
| Admin dashboard | **React + TypeScript**, **Vite**, **Tailwind**, **Recharts/deck.gl** for map analytics | Fast iteration, rich charting/map libraries for govt reporting |
| API layer | **Node.js (NestJS)** for CRUD/business APIs, **FastAPI (Python)** for ML inference endpoints | NestJS gives structured, typed REST/GraphQL for app teams; FastAPI is the natural home for the ETA/crowd models (same language as training) |
| Real-time transport | **MQTT (EMQX broker)** for bus→server GPS ingestion, **Socket.IO/WebSocket** for server→app live updates | MQTT is purpose-built for lossy, low-bandwidth, many-small-messages IoT-style telemetry (this is exactly a GPS-ping problem); WebSocket serves rich live UI updates to phones |
| Stream processing | **Apache Kafka** (or **Redpanda** for lighter ops) + **Kafka Streams/Flink** for windowed ETA + crowd recompute | Decouples ingestion from consumers (app fan-out, ML scoring, analytics DB) so a spike in one bus fleet doesn't stall others |
| Geospatial engine | **PostGIS** (on PostgreSQL) for route/stop geometry, map-matching, nearest-stop queries | Battle-tested GIS queries (ST_LineLocatePoint, ST_Distance) directly power ETA and map-matching |
| Time-series store | **TimescaleDB** (Postgres extension) for GPS trail history | Efficient for "position of bus X over last N minutes", auto-partitioning, retention policies |
| Cache | **Redis** | Sub-second "current bus location" and "current passenger count" lookups feeding the map |
| ML serving | **FastAPI + ONNX Runtime** (models exported to ONNX for fast CPU inference) | Keeps inference latency low without needing GPU boxes for a small-city deployment |
| Ticketing/payments | **Razorpay/UPI (BharatQR, NPCI)** integration, PDF/QR ticket via **Node service** | UPI is the default rail for Indian govt digital payments; QR tickets scan offline by conductor app |
| Auth | **Firebase Auth / Keycloak** (self-hosted for govt data sovereignty), phone-OTP first | Govt data residency preference → Keycloak on-prem is safer for production, Firebase fine for hackathon demo speed |
| Notifications | **FCM (push)** + **SMS gateway (MSG91/Twilio-India)** for feature-phone-adjacent users | Push for smart-app users, SMS fallback for delay alerts to non-smartphone or low-data users |
| Maps | **OpenStreetMap + MapLibre GL** (not Google Maps) | Zero per-load licensing cost at govt scale, works with offline tile caching for low-bandwidth areas |
| Voice/Chatbot | **Whisper (speech-to-text)** + **IndicTrans2 / Bhashini API** for Punjabi/Hindi/English + an LLM (open-weight, e.g. **Llama 3.1 8B** fine-tuned or hosted via API) for intent handling, wired to booking APIs via function-calling | Bhashini is the Govt of India's own multilingual/voice stack — natural fit and easy to justify to SIH judges as "aligned with Digital India" |
| Infra/hosting | **AWS/Azure India region** or **NIC (National Informatics Centre) cloud** for actual govt deployment; **Docker + Kubernetes (k3s for hackathon demo, EKS/AKS for scale)** | NIC cloud is often mandated for state govt data; k3s keeps the demo lightweight |
| CI/CD | GitHub Actions → Docker registry → k8s rollout | Standard, judge-legible |
| Observability | **Grafana + Prometheus**, **Sentry** for app crash analytics | Needed to show "production-readiness" thinking to judges |

### 1.3 Low-bandwidth adaptations (this is what wins PS 25013 specifically)
- GPS pings sent as **compact binary/protobuf**, not verbose JSON (~20-40 bytes/ping vs 200+ bytes JSON).
- **Adaptive ping interval**: 5s when app is foregrounded/near a stop, 15-20s cruising, backs off further on poor signal (detected via Android `TelephonyManager` signal strength).
- Driver app **buffers pings locally (SQLite)** and batch-uploads on reconnect if offline.
- Passenger app map tiles **cached offline** for the town/route once viewed.
- **Degraded UI mode**: if bandwidth is very low, ETA text-only view replaces live map rendering.
- SMS/USSD-style "*Track [Bus No]*" fallback for basic-phone users routed through the SMS gateway, hitting a lightweight text API.

---

## 2. Dataset & Model Training

Two ML problems: **ETA prediction** and **passenger-count / crowd prediction**. Neither needs deep learning to win — the judges reward *correctness and realism*, not model size.

### 2.1 Data sources

| Data | Source for hackathon demo | Source for real deployment |
|---|---|---|
| Bus GPS traces | Simulated (see 2.2) over real Punjab town road network (OSM) | Actual GPS from PRTC/PUNBUS fleet telematics (many buses already have VLTD — Vehicle Location Tracking Devices, mandated under MoRTH AIS-140) |
| Route & stop geometry | OSM extract for target city (e.g. Bathinda, Patiala, Pathankot) | State Transport Dept GTFS-like route master data |
| Traffic/road speed | OSRM/Valhalla routing engine time estimates, synthetic congestion factors by hour | Historical VLTD speed logs + traffic API |
| Passenger boarding counts | Synthetic Poisson-process generator calibrated to time-of-day/route patterns (peak hour multipliers, weekday/weekend, school-time spikes) | IR/ultrasonic door sensors or CCTV person-counting (see 2.4) + ticket sale counts |
| Weather (affects ETA/ridership) | OpenWeatherMap historical API | Same, live |
| Calendar (festivals/holidays) | Manually curated Punjab holiday calendar | Same |

**AIS-140 mention is important** — flag to judges that real PRTC/PUNBUS buses already carry government-mandated GPS trackers, so the ingestion layer is designed to be a drop-in consumer of that existing hardware, not a new hardware ask (huge deployability point).

### 2.2 Simulating a realistic training dataset (hackathon demo)
1. Pick 2-3 real routes in a target small city using OSM + a routing engine (OSRM) to get the actual road-following polyline.
2. Generate synthetic "trips": sample a departure time, then walk the route at a speed drawn from a time-of-day-conditioned distribution (slower 8-10am/5-7pm, normal midday), inject random dwell time at each stop (10-90s, higher at high-footfall stops), add GPS jitter noise (~5-15m).
3. Repeat for ~60-90 days of "virtual operation" → tens of thousands of trip records. This gives enough volume for a supervised ETA model while being fully explainable to judges as "we bootstrap with a physics + statistics simulator, calibrated against publicly available average trip-time data for the routes, and the model is designed to retrain online once real VLTD/ticketing data flows in."
4. For passenger counts, layer a Poisson boarding/alighting process per stop with peak-hour lambda multipliers and weekday/weekend/exam-season variation.

### 2.3 ETA Prediction Model
- **Framing:** given (current position along route, time of day, day of week, weather, distance/segments remaining, historical segment travel times), predict arrival time at each downstream stop.
- **Model:** Gradient-boosted trees (**LightGBM** or **XGBoost**) on engineered features — simplest thing that reliably wins vs. deep models with this data volume, and it's fast enough for CPU inference at fleet scale.
  - Features: segment historical avg speed (last 7/30 days), time-of-day bucket, day-of-week, distance-to-stop, current bus delay-vs-schedule, weather bucket, upcoming-stop dwell prior, live traffic factor.
  - Baseline to beat: naive "distance / route's historical average speed."
- **Optional upgrade for judge-wow-factor:** a small **GRU/LSTM sequence model** over the last N GPS pings per segment for buses on routes with enough live data volume, ensembled with the GBM for cold-start routes. Present this as a "hybrid: statistical model for cold-start, deep model kicks in once a route has sustained live telemetry" — shows layered thinking.
- **Evaluation:** MAE / RMSE on held-out trips, target **MAE < 2 minutes** for stops within 10 minutes' distance (the metric that actually matters to a waiting passenger).
- **Online correction:** every live GPS ping recomputes remaining-route ETA using current speed + the model's segment priors (simple Kalman-filter-style blending of "model prediction" and "current live pace") — this is what makes it feel "real-time" rather than a static prediction.

### 2.4 Passenger Count / Crowd Prediction
Two complementary layers:
- **Live count (in-bus):** cheapest reliable hackathon-demo approach is **conductor app manual counter buttons** (+1/-1 at each door, or a boarding/alighting tally tied to ticket validation) feeding a live Redis counter — completely deployable on day one with zero new hardware. For a hardware-forward add-on, mention **IR beam break sensors** or a **low-cost camera + lightweight CV (YOLOv8n) person-counting at doors** as a Phase-2 upgrade — cite it but don't over-invest hackathon time here since PS is scored on tracking/ETA primarily.
- **Predicted count at next stop:** small regression model (same GBM approach) trained on historical boarding/alighting-per-stop patterns conditioned on time-of-day/day/route/current occupancy → predicts "≈14 people likely to board, ≈6 to alight at Stop X," giving the passenger a decision-support signal ("this bus will be full/comfortable when it reaches you").

### 2.5 Model ops
- Models exported to **ONNX**, served via FastAPI, called by the stream processor per GPS-ping-batch (not per single ping, to control compute cost).
- Weekly retraining job (Airflow/cron) as real trip data accumulates; drift monitored via rolling MAE dashboard (feeds into the Admin analytics view — nice cross-link to task 3).

---

## 3. Admin Dashboard (Presentation Layer for Government Authorities)

### 3.1 Screens
1. **Live Fleet Map** — all active buses as moving markers (color-coded: on-time / delayed / crowded), click-through to a single bus's live trip, driver, occupancy, delay-vs-schedule.
2. **Route Performance** — per-route on-time %, average delay, average occupancy heatmap by hour, "problem segments" flagged where actual speed consistently undercuts schedule (helps re-time timetables).
3. **Passenger Load Analytics** — ridership by route/stop/hour, weekday vs weekend curves, ticket-revenue vs ridership correlation.
4. **Demand-Supply Planning View** — overlay predicted demand (from the crowd model, aggregated) against current fleet allocation per route; auto-flags "Route 14 is over-supplied 11am-3pm, under-supplied 5-7pm" style recommendations — this is the single highest-scoring feature for a *government-authority-facing* tool, because it turns tracking data into a planning decision, which is the actual policy ask behind "Demand–supply patterns for future planning."
5. **Alerts & SOS panel** — breakdown reports, SOS button presses from driver/passenger apps, geofence route-deviation alerts.
6. **Model Health** — ETA MAE trend, data-freshness indicators per bus (last-ping-age), so operators know if a device has gone dark.

### 3.2 Presentation tech
- **React + MapLibre GL** for the live map (deck.gl layer for heatmaps).
- **Recharts** for time-series/bar analytics; export-to-PDF/CSV for offline govt reporting (a very "government workflow" detail — bureaucracy likes exportable reports).
- Role-based views: District Transport Officer sees their district only; State HQ sees all districts aggregated (RBAC via Keycloak roles).

---

## 4. Web App / Mobile App — Screens & Flows

### 4.1 Passenger App
- **Home**: nearby stops (geofenced), search route/destination, "Track my bus" quick action.
- **Live Map**: bus marker moving on route polyline, ETA countdown per upcoming stop, current occupancy badge (Low/Medium/Full with color), tap bus → trip details (driver name, bus no., next 3 stops with ETA).
- **Ticketing**: select route/stop pair → fare auto-calculated → UPI pay → QR e-ticket (works offline once downloaded, conductor scans/validates via driver app even without conductor's own connectivity, validation syncs later).
- **AI Voice Chat-bot ("Amigo")**: "Book me a ticket from Bus Stand to Civil Lines" (Punjabi/Hindi/English) → STT (Bhashini/Whisper) → intent parsed → confirms fare/route → completes booking via function-calling into the ticketing API → TTS confirmation. Also answers "Where is bus 14?" / "Is the 5:30 bus late?" conversationally.
- **Multilingual**: Punjabi (Gurmukhi), Hindi, English toggle; all UI strings + bot responses localized via i18n + Bhashini translation for dynamic text.
- **Accessibility**: large-text mode, screen-reader labels, voice-first flow doubles as an accessibility feature for visually impaired commuters (good judge talking point, ties to the Bathinda accident precedent around safety-for-all).
- **SOS button**: one-tap alert with live location to a control-room number.

### 4.2 Driver & Conductor App
- **Login** (phone OTP, linked to depot-issued ID).
- **Route Selection**: pick assigned route/shift from a dropdown populated by depot roster (or manual select in demo).
- **Start/End Trip**: single big button; starts GPS streaming (foreground service, survives screen-off) and creates a "trip" record server-side; End Trip closes it and triggers analytics ingestion.
- **On-trip screen**: current stop, next stop ETA (for driver's own pacing awareness), passenger tally +/- buttons, "delay reason" quick-tags (traffic/breakdown/diversion) that feed straight into admin analytics.
- **Ticket Validation**: camera-based QR scan (works offline, syncs on reconnect) or manual ticket entry fallback.
- **SOS/Breakdown report**: flags admin dashboard instantly + reroutes passengers' ETA calc for other buses on that route.

### 4.3 Cross-cutting UX principle
Everything a driver does must survive a dropped connection and a low-end device — this is scored implicitly by judges who've read the "low-bandwidth environments" line in the PS twice.

---

## 5. Making It Run Real-Time — System Architecture

```
[Driver App] --GPS ping (protobuf, MQTT publish)--> [EMQX MQTT Broker]
                                                            |
                                                            v
                                          [Kafka topic: raw-gps-pings]
                                                            |
                                  -------------------------------------------------
                                  |                         |                     |
                                  v                         v                     v
                     [Stream Processor:          [TimescaleDB:            [Redis: latest
                      map-match to route,          historical GPS          position + occupancy
                      call ETA model,               trail]                 cache per bus]
                      compute crowd est.]
                                  |
                                  v
                     [Kafka topic: bus-state-updates]
                                  |
                                  v
                 [WebSocket Gateway (Socket.IO, horizontally scaled)]
                                  |
                     ---------------------------------
                     |                                |
                     v                                v
           [Passenger App: live map,          [Admin Dashboard:
            ETA, crowd badge]                   live fleet view]
```

### 5.1 Real-time mechanics
1. **Ingestion**: driver app publishes a tiny GPS+status packet to MQTT every 5-20s (adaptive interval, see §1.3). EMQX handles tens of thousands of concurrent low-power MQTT connections cheaply — this is the standard pattern for fleet telemetry at government/municipal scale (used in real AIS-140 VLTD backends).
2. **Buffering & fan-out**: MQTT bridges into Kafka so that a burst of pings never overwhelms downstream consumers, and multiple consumers (map-matcher, historical logger, analytics) each read independently without blocking each other.
3. **Map-matching**: raw lat/lon is snapped onto the correct route polyline using PostGIS `ST_LineLocatePoint`, so "% of route completed" and "distance to next stop" are geometrically accurate even with noisy GPS.
4. **ETA scoring**: FastAPI ML service is called (batched, ~1x/sec across all active buses, not per-ping) with the current state; result written to Redis (sub-ms read) and pushed onward.
5. **Live push**: WebSocket gateway holds one subscription per "route" or "bus" room; only clients actually viewing that bus/route receive updates — keeps payload volume proportional to actual viewers, not total fleet size.
6. **Horizontal scale**: WebSocket gateway is stateless behind a load balancer with Redis pub/sub as the backplane (Socket.IO's `redis-adapter`), so it scales out for city-wide rollout without a redesign.
7. **Resilience**: if a bus goes dark (no ping > 60s), admin dashboard flags it and passenger ETA falls back to last-known-speed extrapolation with a "signal lost, estimate may be stale" badge rather than silently freezing — an honest-UX detail judges notice.

### 5.2 For the hackathon demo specifically
- Since real buses won't be wired up during judging, ship a **GPS simulator script** that replays the synthetic trip generator (§2.2) as live MQTT publishes, so the *entire* real-time pipeline — MQTT → Kafka → ML → WebSocket → both apps — runs exactly as it would in production, just fed by simulated buses instead of real VLTD hardware. This is the single most convincing thing you can show a jury: not a canned demo video, but the live pipeline reacting to injected GPS movement in real time on stage.

---

## 6. Hackathon Execution Plan (build order, ~36-48hr sprint)

1. **Hr 0-4**: Repo scaffold, Postgres/PostGIS + Redis + Kafka/EMQX docker-compose, pick 2 demo routes in OSM, load route/stop geometry.
2. **Hr 4-10**: GPS simulator + MQTT→Kafka bridge + WebSocket gateway skeleton; get a dot moving on a MapLibre map end-to-end. (This is your safety-net MVP — get this working before anything else.)
3. **Hr 10-18**: Driver app (start/end trip, live GPS stream, ticket validation stub); Passenger app live map + ETA display (start with naive distance/avg-speed ETA, swap in ML later).
4. **Hr 18-26**: Train/plug in LightGBM ETA model + crowd model on simulated dataset; wire into stream processor.
5. **Hr 26-32**: Ticketing (UPI sandbox) + QR generation/scan; Admin dashboard core views (live map, route performance).
6. **Hr 32-40**: Multilingual UI strings, voice chatbot (Whisper/Bhashini + LLM function-calling to booking API) — do this once the booking API is stable, not before.
7. **Hr 40-46**: Demand-supply analytics view, SOS/alerts, polish, offline-mode fallbacks.
8. **Hr 46-48**: Rehearse the live-simulator demo, prepare the AIS-140/deployability talking points, record backup video in case of venue Wi-Fi issues.

**Judging-day risk mitigation:** always have a recorded fallback video of the live pipeline working, since venue networks are notoriously unreliable — the irony of a bandwidth-constrained tracking app failing on hackathon Wi-Fi is exactly the kind of thing to plan around.

---

## 7. Why This Wins Against the PS's Actual Ask
- Directly answers "low-bandwidth optimized" with concrete engineering (protobuf pings, adaptive intervals, offline queues, SMS fallback) rather than a slide bullet.
- Uses **AIS-140** as the real-world hook — shows you understand PRTC/PUNBUS buses already have GPS hardware, so this is a *software integration* play, not a hardware moonshot — that's a deployability point judges specifically reward.
- Turns tracking data into **planning intelligence** (demand-supply view) — this is what makes it a "government dashboard" and not just a Maps clone.
- Multilingual + voice + accessibility ties to inclusion, and the Bathinda 2024 bus-crash context gives a genuine safety narrative (SOS + live tracking) beyond convenience.
- The build order guarantees a working, judge-visible real-time pipeline even if ML/voice polish runs out of time — the core "live GPS → ETA → map" loop is protected first.

---

*Document prepared as a complete SIH 2025 PS-25013 solution architecture — covering tech stack, dataset/model strategy, dashboard design, app UX, and real-time systems design, with a build-order plan for hackathon execution.*
