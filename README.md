# FieldTrack — Employee Tracking & Attendance System

<div align="center">

![FieldTrack](https://img.shields.io/badge/FieldTrack-Employee%20Tracking-4F46E5?style=for-the-badge&logo=fastapi&logoColor=white)

**Production-grade employee tracking and attendance system with real-time GPS, polygon geofencing, offline-first sync, FCM notifications, and comprehensive reporting — engineered for 15-100 employees on a single VPS without architecture changes.**

[![FastAPI](https://img.shields.io/badge/FastAPI-0.115-009688?style=flat-square&logo=fastapi&logoColor=white)](https://fastapi.tiangolo.com/)
[![Python](https://img.shields.io/badge/Python-3.11-3776AB?style=flat-square&logo=python&logoColor=white)](https://www.python.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15-4169E1?style=flat-square&logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![PostGIS](https://img.shields.io/badge/PostGIS-3.4-4169E1?style=flat-square&logo=postgresql&logoColor=white)](https://postgis.net/)
[![Redis](https://img.shields.io/badge/Redis-7-DC382D?style=flat-square&logo=redis&logoColor=white)](https://redis.io/)
[![Flutter](https://img.shields.io/badge/Flutter-3.22-02569B?style=flat-square&logo=flutter&logoColor=white)](https://flutter.dev/)
[![React](https://img.shields.io/badge/React-18-61DAFB?style=flat-square&logo=react&logoColor=black)](https://reactjs.org/)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?style=flat-square&logo=docker&logoColor=white)](https://www.docker.com/)
[![License](https://img.shields.io/badge/License-Proprietary-red.svg?style=flat-square)](LICENSE)

[Documentation](#documentation) | [Quick Start](#quick-start) | [API Reference](#api-endpoints) | [Architecture](#architecture) | [Deployment](#deployment)

**GitHub:** https://github.com/OnlyArkMani/FieldTrack-Final

</div>

---

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [Technology Stack](#technology-stack)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Scalability](#scalability)
- [API Endpoints](#api-endpoints)
- [Deployment](#deployment)
- [Documentation](#documentation)
- [Project Structure](#project-structure)
- [Contributing](#contributing)

---

## Overview

**FieldTrack** is a full-stack, production-grade employee tracking and attendance system. It combines a FastAPI backend with async PostgreSQL and Redis, a Flutter mobile app with offline-first architecture, a React admin dashboard with real-time WebSocket updates, and integrated geofencing via PostGIS — all containerised and deployable to a single 2 vCPU / 4 GB RAM VPS.

Designed for small-to-medium teams (15-100 employees) with zero architecture changes required to scale within that range. Includes automatic daily backups to Backblaze B2, audit logging for compliance, and comprehensive reporting (CSV/Excel/PDF exports).

---

## Key Features

### Real-Time GPS Tracking

- Live location updates with hybrid cadence: 2-5 minutes when moving, 10-15 minutes when stationary
- Battery-aware tracking that adjusts frequency based on device battery level
- Mock GPS detection flagged (not hard-blocked) for edge cases
- Offline tile caching via OpenStreetMap — employees can view maps without internet
- Sync-lag metrics from device capture time vs. server arrival timestamp

### Attendance State Machine

- 4-state workflow: START → BREAK → RESUME → END
- Work summary on end-of-day (lightweight text field for notes)
- Daily reminders (9 AM clock-in, 6 PM clock-out, 11 PM cleanup)
- Session tracking with millisecond precision for compliance

### Geofencing and Polygon Detection

- Polygon geofencing (not circles) for precise office/site boundaries via PostGIS ST_Contains()
- Automatic zone entry/exit detection with GIST spatial index
- Event logging for compliance audits and reports
- Distance calculations from location trails

### Reports and Analytics

- CSV, Excel, PDF exports with configurable date ranges
- Attendance summaries by employee, team, and date
- Distance and zone-time analytics with custom report types
- Async generation with polling and auto-cleanup after retention period

### Push Notifications (Firebase Cloud Messaging)

- Attendance reminders (clock-in/out prompts)
- GPS alerts (zone entry/exit, low battery, no internet)
- Admin announcements broadcast to all employees
- Scheduled delivery respecting business hours and timezones

### Offline-First Architecture

- Local SQLite queue on mobile with hybrid sync cadence
- Deduplication via Redis (6-hour window) prevents duplicate processing
- Async validation — failed syncs are retried without blocking the UI
- Conflict resolution for offline changes vs. server updates

### Role-Based Access Control

- Admin (web-only) — full control, user management, reports, dashboards
- Supervisor (mobile) — team-scoped view, attendance records, team analytics
- Employee (mobile) — personal attendance, GPS tracking, profile settings

### Dark and Light Theme

- System theme toggle from the Profiles tab (persistent across sessions)
- Warm color palette (Amber primary, Soft Purple secondary) designed for accessibility
- Smooth transitions across all screens (350ms animations)

### Mobile-First Design (Android)

- Low-end device support — tested on budget Android phones (min SDK 21)
- Location and timestamp based attendance (no biometrics)
- Icon-driven UI with minimal text
- Full offline operation — all core features work without internet

---

## Technology Stack

### Backend

| Component | Version | Purpose |
|-----------|---------|---------|
| FastAPI | 0.115+ | Async web framework with auto-generated OpenAPI docs |
| Python | 3.11+ | Async throughout via asyncpg + SQLAlchemy 2.0 |
| PostgreSQL | 15 + PostGIS | Spatial queries for geofencing; async via asyncpg |
| Redis | 7 | Cache, session management, sync deduplication |
| APScheduler | 3.11+ | In-process job scheduler (no Celery dependency) |
| Alembic | 1.15+ | Database migrations with async support |
| PyJWT | 2.10+ | JWT token handling with separate access/refresh secrets |
| Passlib + Bcrypt | 1.7.4 | Password hashing (12 rounds) |

### Frontend

| Component | Version | Purpose |
|-----------|---------|---------|
| React | 18.3+ | UI framework for admin dashboard |
| Vite | 5.3+ | Fast build tool and dev server |
| Tailwind CSS | 3.4+ | Utility-first CSS framework |
| Zustand | 4.5+ | Lightweight state management |
| React Router | 6.24+ | Client-side routing |
| Axios | 1.7+ | HTTP client with interceptors |
| React Query | 5.51+ | Data fetching and caching |
| Recharts | 2.12+ | Charts and data visualizations |
| Leaflet | 1.9+ | Interactive mapping library |

### Mobile (Flutter)

| Component | Version | Purpose |
|-----------|---------|---------|
| Flutter | 3.22+ | Cross-platform development (Android min SDK 21) |
| Riverpod | 2.6+ | App-wide state management |
| GoRouter | 14.8+ | Type-safe routing with deep linking |
| flutter_map | 7.0+ | OpenStreetMap rendering |
| flutter_map_tile_caching | 9.1+ | Offline map tile storage |
| geolocator | 13.0+ | GPS location services |
| background_locator_2 | 2.0+ | Background location tracking |
| Firebase Messaging | 15.2+ | Push notifications (FCM) |
| Dio | 5.8+ | HTTP client with retry logic |
| sqflite | 2.4+ | Local SQLite database for offline queue |

### Deployment Infrastructure

| Component | Purpose |
|-----------|---------|
| Docker | Container runtime and orchestration |
| Docker Compose | Multi-service deployment definition |
| Nginx | Reverse proxy, rate limiting, TLS termination |
| Gunicorn + Uvicorn | ASGI server with worker process management |
| Prometheus + Grafana | Metrics collection and visualization |
| Uptime Kuma | Uptime monitoring and status page |

---

## Quick Start

### Prerequisites

- Docker and Docker Compose v2.0 or later
- Git
- For local development: Python 3.11+, Node.js 18+, Flutter 3.22+

### Local Development Setup

```bash
# 1. Clone the repo
git clone https://github.com/OnlyArkMani/FieldTrack-Final.git
cd FieldTrack-Final

# 2. Create environment file
cp .env.example .env
# Fill in secrets (see Configuration below)

# 3. Start all services (postgres, redis, app, nginx)
docker compose up -d --build

# 4. Run migrations
docker compose exec app alembic upgrade head

# 5. Check health
curl http://localhost:8090/api/v1/health
# {"status":"ok","env":"development"}

# 6. Open dashboard
# Admin web: http://localhost:8090 (will prompt for login)
# API docs: http://localhost:8090/api/v1/docs
```

### Create Admin User

```bash
# Inside the app container (one-time)
docker compose exec app python -c "
from app.core.database import engine
from sqlalchemy.orm import Session
from app.models.user import User
from app.core.security import hash_password
import asyncio

async def create_admin():
    async with engine.begin() as conn:
        result = await conn.execute('...')  # insert user
        await conn.commit()

asyncio.run(create_admin())
"
# Or use the app's POST /api/v1/auth/signup endpoint (if enabled)
```

---

## Configuration

### Environment Variables

**Database**
```env
DATABASE_URL=postgresql+asyncpg://fieldtrack:PASSWORD@postgres:5432/fieldtrack
DB_POOL_SIZE=10           # Raise to 20+ at 100 employees
DB_MAX_OVERFLOW=5
```

**Redis**
```env
REDIS_URL=redis://:PASSWORD@redis:6379/0
```

**JWT & Auth**
```env
JWT_ACCESS_SECRET=<openssl rand -hex 32>
JWT_REFRESH_SECRET=<openssl rand -hex 32>  # DIFFERENT from access
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=15
REFRESH_TOKEN_EXPIRE_DAYS=7
```

**Firebase Cloud Messaging (FCM)**
```env
FCM_SERVICE_ACCOUNT_FILE=/run/secrets/fcm-service-account.json
FCM_PROJECT_ID=your-firebase-project-id
```

> **FCM Setup Note:** Download the Firebase service account JSON from Firebase Console → Project Settings → Service Accounts → Generate New Private Key. Place it at the path above. Also place `google-services.json` (Firebase Console → Project Settings → Android app) at `mobile/android/app/google-services.json` before building the Flutter APK — this file is excluded from git.

**Reports**
```env
REPORT_STORAGE_DIR=/srv/fieldtrack/reports
REPORT_RETENTION_MINUTES=60  # Auto-cleanup after 1 hour
```

**App & Server**
```env
APP_ENV=development              # or staging, production
DEBUG=true                       # MUST be false in prod
NGINX_HTTP_PORT=8090            # 8080/8081 unavailable
UVICORN_WORKERS=2               # Match vCPU count
```

See `.env.example` for all options.

---

## Project Structure

```
FieldTrack/
├── README.md                          # This file
├── ARCHITECTURE.md                    # Backend design decisions
├── DEPLOYMENT_CHECKLIST.md            # Production deployment steps
├── RESTORE.md                         # Backup restoration procedure
│
├── app/                               # FastAPI backend
│   ├── main.py                        # Entry point, routes registration
│   ├── core/                          # Infrastructure
│   │   ├── config.py                  # Pydantic settings with validation
│   │   ├── security.py                # JWT, bcrypt, rate limiting
│   │   ├── database.py                # Async SQLAlchemy session factory
│   │   ├── redis.py                   # Async Redis client & key registry
│   │   └── dependencies.py            # FastAPI dependency injection
│   ├── api/v1/                        # HTTP routes (zero business logic)
│   │   ├── auth.py                    # Login, refresh, logout, password reset
│   │   ├── employees.py               # Employee CRUD, profile
│   │   ├── teams.py                   # Team management, supervisor assignment
│   │   ├── attendance.py              # Clock in/out, state machine
│   │   ├── location.py                # GPS ping submission
│   │   ├── geofencing.py              # Zone creation, entry/exit events
│   │   ├── notifications.py           # FCM subscription, admin broadcast
│   │   ├── devices.py                 # Device info, FCM token registration
│   │   ├── reports.py                 # CSV/Excel/PDF export endpoints
│   │   ├── sync.py                    # Offline queue batch processing
│   │   └── ws.py                      # WebSocket for admin live dashboard
│   ├── services/                      # Business logic & transactions
│   │   ├── attendance.py              # State validation, session creation
│   │   ├── location.py                # GPS processing, geofence check
│   │   ├── sync.py                    # Dedup, conflict resolution
│   │   ├── reports.py                 # Export generation (CSV/Excel/PDF)
│   │   └── notification.py            # FCM message building
│   ├── repositories/                  # Database queries (zero commits)
│   ├── models/                        # SQLAlchemy ORM definitions
│   ├── schemas/                       # Pydantic request/response models
│   ├── workers/                       # APScheduler jobs
│   │   ├── attendance_reminder.py     # Daily clock-in/out reminders
│   │   ├── geofence_processor.py      # Zone event handling
│   │   ├── fcm_retry.py               # Failed notification retries
│   │   └── sync_cleanup.py            # Prune old location_logs, sync_queue
│   └── utils/                         # Pure helpers (haversine, export builders)
│
├── admin-web/                         # React admin dashboard
│   ├── src/
│   │   ├── App.jsx                    # Root component, router
│   │   ├── pages/                     # Route-level pages
│   │   │   ├── Dashboard.jsx          # Live employee map + status
│   │   │   ├── Employees.jsx          # Employee table, bulk actions
│   │   │   ├── Reports.jsx            # Export builder & history
│   │   │   └── Settings.jsx           # App configuration
│   │   ├── components/                # Reusable UI components
│   │   └── hooks/                     # Custom React hooks
│   ├── vite.config.js
│   ├── tailwind.config.js
│   └── package.json
│
├── mobile/                            # Flutter mobile app (Android-first)
│   ├── lib/
│   │   ├── main.dart                  # App entry, theme setup
│   │   ├── core/
│   │   │   ├── location/              # GPS service wrapper
│   │   │   ├── storage/               # SQLite queue, preferences
│   │   │   └── api/                   # HTTP client, retry logic
│   │   ├── features/
│   │   │   ├── attendance/            # Clock-in/out screens
│   │   │   ├── location/              # Map view, GPS status
│   │   │   ├── reports/               # Export preview/download
│   │   │   └── profile/               # Settings, dark/light toggle
│   │   └── widgets/                   # Reusable Flutter widgets
│   ├── android/                       # Android-specific config
│   │   └── app/google-services.json   # Firebase config (not in git)
│   ├── pubspec.yaml
│   └── pubspec.lock
│
├── nginx/
│   ├── nginx.conf                     # Dev/staging proxy config
│   └── nginx.prod.conf                # Production with TLS
│
├── postgres/                          # Database utilities
│   └── init.sql                       # PostGIS setup (if needed)
│
├── alembic/                           # Database migrations
│   ├── env.py                         # Async migration runner
│   ├── script.py.mako                 # Migration template
│   └── versions/
│       └── 0001_initial_schema.py     # Initial schema with PostGIS
│
├── monitoring/                        # Prometheus + Grafana + Uptime Kuma
│   └── docker-compose.monitoring.yml
│
├── scripts/
│   ├── server_setup.sh                # VPS first-time setup
│   ├── ssl_setup.sh                   # Let's Encrypt + certbot
│   ├── backup.sh                      # Automated backup to B2
│   ├── build_flutter.sh               # Flutter Android split APKs
│   └── build_admin.sh                 # Admin web build & deploy
│
├── tests/                             # Pytest test suite
│   ├── conftest.py                    # Fixtures, test DB
│   ├── test_auth.py
│   ├── test_attendance.py
│   └── test_sync.py
│
├── docs/
│   └── REDIS_KEYS.md                  # Complete Redis schema reference
│
├── docker-compose.yml                 # Development (postgres, redis, app, nginx)
├── docker-compose.prod.yml            # Production (with health checks, limits)
├── Dockerfile                         # Multi-stage, non-root, python:3.11-slim
├── .env.example                       # Template environment file
├── .env.prod.example                  # Production template
├── requirements.txt                   # Python dependencies (pinned majors)
└── .gitignore
```

---

## API Endpoints

### Authentication
- `POST /api/v1/auth/signup` — Create user account
- `POST /api/v1/auth/login` — Get access + refresh tokens
- `POST /api/v1/auth/refresh` — Rotate access token
- `POST /api/v1/auth/logout` — Revoke tokens
- `POST /api/v1/auth/forgot-password` — Initiate password reset

### Employees & Teams
- `GET /api/v1/employees` — List all employees (admin) / own profile (employee)
- `PUT /api/v1/employees/{id}` — Update employee
- `GET /api/v1/teams` — List teams
- `POST /api/v1/teams` — Create team (admin only)
- `PUT /api/v1/teams/{id}` — Update team assignment

### Attendance
- `POST /api/v1/attendance/start` — Begin work day
- `POST /api/v1/attendance/break` — Begin break
- `POST /api/v1/attendance/resume` — Resume after break
- `POST /api/v1/attendance/end` — End work day (with optional summary)
- `GET /api/v1/attendance/current` — Current session state
- `GET /api/v1/attendance/history` — Historical attendance records

### Location & Geofencing
- `POST /api/v1/locations/ping` — Submit GPS location (mobile)
- `GET /api/v1/locations/live` — Get all employees' current location (admin, cached in Redis)
- `POST /api/v1/geofences` — Create zone polygon
- `GET /api/v1/geofences` — List all zones
- `GET /api/v1/geofences/{id}/events` — Zone entry/exit log

### Sync (Mobile Offline Queue)
- `POST /api/v1/sync/batch` — Submit batch of offline changes
- `GET /api/v1/sync/status` — Check sync queue status

### Reports
- `POST /api/v1/reports/attendance` — Export attendance CSV/Excel/PDF
- `POST /api/v1/reports/location` — Export location history
- `GET /api/v1/reports` — List generated exports
- `GET /api/v1/reports/{id}` — Download export file

### Notifications
- `POST /api/v1/notifications/subscribe` — Register FCM token
- `POST /api/v1/notifications/broadcast` — Send admin announcement (admin only)

### WebSocket (Admin Live Dashboard)
- `WS /api/v1/ws/admin-live` — Real-time employee location stream (admin only)

See `http://localhost:8090/api/v1/docs` (Swagger UI) for complete endpoint documentation with request/response schemas.

---

## Key Workflows

### Attendance Workflow
1. Employee taps **START** (9 AM) → `attendance_sessions` created with status `STARTED`
2. Optional: Tap **BREAK** → status becomes `ON_BREAK`, pause time recorded
3. Tap **RESUME** → status becomes `RESUMED`, pause duration calculated
4. Tap **END** (5 PM) → status becomes `ENDED`, total work hours calculated, optional summary notes saved
5. Admin can view daily summary per employee in reports

**State Machine Validation** (enforced in Redis):
```
START → BREAK → RESUME → BREAK → RESUME → ... → END
  ❌ Cannot BREAK before START
  ❌ Cannot RESUME without BREAK
  ❌ Cannot END during BREAK
```

### GPS & Geofencing Workflow
1. Employee's phone pings location every 2-5 min (moving) or 10-15 min (stationary)
2. Device battery level + network status recorded on each ping
3. Server stores ping in `location_logs` + Redis cache (2-hour TTL for last-known position)
4. Every ping checked against all `geofences` polygons via PostGIS `ST_Contains()`
5. If zone entry/exit detected → FCM alert sent (async, background)
6. Admin live map shows all employees, last known position, status (Active/Idle/Offline/Low Battery)

### Offline Sync Workflow
1. Mobile device queues changes (attendance, location) in SQLite when offline
2. When connectivity restored, app submits entire queue as **batch** (`POST /api/v1/sync/batch`)
3. Server deduplicates via Redis `SET NX` on hash of (user_id, timestamp, entity_id)
4. Duplicates are skipped silently; batch returns success
5. Conflicts checked: if attendance already exists for same date, device version accepted if later
6. All changes committed atomically to Postgres; Redis dedup key expires after 6 hours

### Report Export Workflow
1. Admin chooses date range + report type (attendance, location, distance zones)
2. Server queries Postgres + generates file (CSV/Excel/PDF)
3. File stored in named volume (`reports_data`) with TTL marker in Redis
4. Admin downloads via S3-like presigned URL or inline
5. Files auto-prune after `REPORT_RETENTION_MINUTES` (default 60)

---

## Architecture

### Async Throughout
- **FastAPI + asyncpg + SQLAlchemy 2.0** — async/await everywhere
- **Zero blocking I/O** on critical paths (location pings, sync batches)
- **Scales to 100 employees on 2 vCPU** without Celery or message brokers

### Database Design
- **PostGIS for spatial queries** — polygon geofencing without app-level math
- **Partial indexes** — only index active rows (pending syncs, FCM tokens)
- **Native Postgres enums** for domain states (role, attendance status, etc.)
- **Timestamptz everywhere** (UTC server time, mobile clients localize)
- **Audit logs** (critical events only: login, attendance changes, role changes)

### Redis Strategy
- **Never source of truth** — every key is reconstructible from Postgres
- **Every key has a TTL** — volatile-lru eviction policy, graceful degradation
- **Session fingerprinting** — refresh tokens stored as sha256 hashes (never raw credentials)
- **Deduplication** — sync batches deduplicated via atomic SET NX

### Security
- **JWT with separate secrets** — access (15 min) + refresh (7 days)
- **Refresh token rotation** — session detection of token theft
- **Rate limiting** — 30 req/s per IP (Nginx) + per-endpoint limits (app)
- **Bcrypt password hashing** — 12 rounds
- **Audit trail** — login, attendance changes, role changes logged
- **Non-root Docker** — runs as `app:app`, filesystem read-only except `/srv/fieldtrack`

---

## Deployment

### Infrastructure Requirements

**VPS Specifications:** 2 vCPU, 4 GB RAM, Ubuntu 22.04 LTS

**Resource Allocation:**

```
PostgreSQL:     1 GB
Redis:          256 MB
FastAPI App:    1 GB (2x Uvicorn workers)
Nginx:          128 MB
─────────────────────
Total Used:     ~2.4 GB
Headroom:       ~1.6 GB (OS and surge capacity)
```

**Deployment Steps** (See `DEPLOYMENT_CHECKLIST.md` for complete guide)

```bash
# On VPS
curl -sSL https://your-repo/scripts/server_setup.sh | sudo bash

# Create .env.prod with secrets
scp .env.prod deploy@vps:/opt/fieldtrack/app/.env.prod

# Deploy via Docker Compose
ssh deploy@vps 'cd /opt/fieldtrack/app && docker compose -f docker-compose.prod.yml up -d'

# Run migrations
ssh deploy@vps 'cd /opt/fieldtrack/app && docker compose exec app alembic upgrade head'
```

**TLS and HTTPS Setup**

Automated certificate management via Let's Encrypt and certbot:

```bash
./scripts/ssl_setup.sh your-domain.com
```

This script creates the Nginx production configuration with 443 HTTPS port and automatic renewal.

**Monitoring Stack**

Deploy monitoring services (Prometheus, Grafana, Uptime Kuma):

```bash
docker compose -f monitoring/docker-compose.monitoring.yml up -d
```

Access:
- Grafana: http://your-domain.com:3000 (default credentials: admin / admin)
- Uptime Kuma: http://your-domain.com:3001
- Status page: http://your-domain.com/status

**Automated Backups**

Daily PostgreSQL backups to Backblaze B2 at 2:00 AM UTC. See `RESTORE.md` for recovery procedures.

---

## Testing

```bash
# Run all tests (requires test database)
pytest

# Run specific module
pytest tests/test_attendance.py

# With coverage
pytest --cov=app tests/

# Watch mode (requires pytest-watch)
ptw

# Integration tests (hit real Postgres via docker)
pytest tests/test_integration/ --integration
```

---

## Documentation

- **ARCHITECTURE.md** — Every design decision, assumption, and reasoning
- **DEPLOYMENT_CHECKLIST.md** — Step-by-step production deployment with verification
- **RESTORE.md** — Backup restoration and disaster recovery procedures
- **docs/REDIS_KEYS.md** — Complete Redis key schema, TTLs, and memory budget
- **API Docs** — Auto-generated Swagger UI at `/api/v1/docs` (dev/staging only)

---

## Troubleshooting

### Container won't start
```bash
docker compose logs <service> --tail 100
# Most common: missing .env variable, port conflict, or unhealthy healthcheck
```

### Migrations failed
```bash
docker compose exec app alembic current
docker compose exec app alembic history
docker compose exec app alembic downgrade -1  # Rollback one revision
```

### GPS not showing on admin map
- Confirm device has location permission (check "GPS Disabled" in live status)
- Check Redis for recent keys: `redis-cli --scan --pattern 'location:*'`
- Verify WebSocket connection: browser devtools → Network → WS → `/api/v1/ws/admin-live`

### FCM not delivering
- Check Firebase console → Cloud Messaging → delivery reports
- Verify `FCM_SERVICE_ACCOUNT_FILE` points to valid, non-expired JSON
- Confirm device's FCM token in `device_info` table (stale tokens are expected)

### High memory usage
- Check `docker compose ps` — memory limits enforced, container should restart if exceeded
- Review Redis keys: `redis-cli INFO memory`
- Prune old location logs: `docker compose exec app python scripts/cleanup.py`

---

## Contributing

1. **Code style** — Black (Python), Prettier (JS), Dart formatting
2. **Layering** — API → Services → Repositories → Models (enforced by review)
3. **Migrations** — Always test with real Postgres (Docker Compose test database)
4. **Tests** — New features require unit + integration tests
5. **Documentation** — Update ARCHITECTURE.md and README.md for design changes

---

## 📄 License

[Your License Here]

---

## 📞 Support

For issues, feature requests, or deployment help:
- **GitHub Issues** — Bug reports and feature tracking
- **Documentation** — See ARCHITECTURE.md and DEPLOYMENT_CHECKLIST.md
- **Email** — [contact email]

---

## Roadmap

### Completed

- Attendance state machine (START/BREAK/RESUME/END) with work summary on END
- Real-time GPS tracking with hybrid cadence (2-5 min moving, 10-15 min stationary)
- Polygon geofencing via PostGIS — team-scoped zone assignment with entry/exit events
- Offline-first mobile sync with Redis deduplication (6-hour dedup window)
- CSV, Excel, and PDF report export — async pipeline, auto-prune after retention period
- Distance zones report type — distance traveled + time-in-zone analytics
- Push notifications via Firebase Cloud Messaging (FCM) — reminders, GPS alerts, admin broadcast
- Dark and light theme toggle across mobile and web
- Admin live dashboard with WebSocket real-time updates — per-member live status, expandable team cards
- 31-day employee location trail on admin map — click any employee to replay movement
- Supervisor sees own location in team live view
- Android build: AGP 8.11.1, Gradle 8.14, Kotlin 2.2.20, core desugaring enabled
- Splash screen with correct Android 12+ SplashScreen API integration
- ProGuard/R8 production build configuration
- Pre-deploy hardening: health checks, env-file validation, rollback scripts
- GitHub Actions CI/CD pipeline with automated test + build jobs

### Planned

- Multi-language support (internationalization)
- Time card corrections and approval workflows
- Integration with payroll systems
- WhatsApp and SMS notifications (supplementing FCM)
- Mobile app for iOS (currently Android-only)

---

**Project Status:** Production Ready  
**Last Updated:** June 25, 2026  
**Current Version:** 0.2.0  
**Repository:** https://github.com/OnlyArkMani/FieldTrack-Final
