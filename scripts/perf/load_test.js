/*
 * FieldTrack — k6 load/performance test.
 *
 * WHAT THIS TESTS
 *   Two back-to-back scenarios against the real stack (docker compose up):
 *     1. current_scale  — 20 concurrent employees (today's real headcount),
 *                          for 3 minutes. This is the load FieldTrack actually
 *                          carries right now.
 *     2. target_scale    — ramps 20 -> 100 concurrent employees and holds, to
 *                          validate the "zero architecture change to 100"
 *                          claim in ARCHITECTURE.md before the AWS move.
 *   A third, constant scenario (admin_dashboard) runs the whole time,
 *   simulating 2 supervisors polling the live team view and occasionally
 *   generating a report — the heaviest read endpoints in the system.
 *
 * TIME COMPRESSION (read this before judging the numbers)
 *   Real GPS pings fire every 2-5 min (moving) or 10-15 min (stationary) per
 *   the spec. Waiting that long per VU would make this test take hours for
 *   no benefit, since that real cadence is already proven trivial (see the
 *   capacity analysis in the report: ~0.8 req/s sustained at 100 employees).
 *   This script instead pings every 3-8 seconds per VU — roughly 30-50x the
 *   real-world rate — so the test deliberately measures HEADROOM, not the
 *   literal production rate. Treat results as "how far past real load can
 *   this stack go," not "this is what 100 employees generates."
 *
 * PREREQUISITES
 *   1. Stack running:        docker compose up -d --build
 *   2. Migrations applied:   docker compose exec app alembic upgrade head
 *   3. Test accounts seeded: python scripts/seed_load_test_users.py --count 100 --teams 5
 *      (writes scripts/perf/load_test_users.json, which this script reads)
 *   4. k6 installed (https://k6.io/docs/get-started/installation/) or:
 *        docker run --rm -i -v "$(pwd):/scripts" -w /scripts grafana/k6 run perf/load_test.js
 *
 * RUN
 *   k6 run scripts/perf/load_test.js
 *   k6 run -e BASE_URL=http://localhost:8090 scripts/perf/load_test.js   (override target)
 *   k6 run --summary-export=scripts/perf/results.json scripts/perf/load_test.js   (save numbers for the report)
 *
 * CLEANUP
 *   python scripts/seed_load_test_users.py --cleanup
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Trend } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8090";
const API = `${BASE_URL}/api/v1`;

const users = JSON.parse(open("./load_test_users.json"));
const employees = users.employees;
const supervisors = users.supervisors;

if (employees.length === 0) {
  throw new Error(
    "load_test_users.json has no employees — run scripts/seed_load_test_users.py first."
  );
}

// Custom metrics broken out by endpoint so the report can cite each one,
// not just the blended k6 default.
const gpsPingDuration = new Trend("gps_ping_duration_ms");
const attendanceDuration = new Trend("attendance_duration_ms");
const teamLiveDuration = new Trend("team_live_duration_ms");
const reportGenDuration = new Trend("report_generate_duration_ms");
const loginFailures = new Counter("login_failures");
const businessErrors = new Counter("business_logic_errors"); // non-2xx that ISN'T a server crash

export const options = {
  scenarios: {
    current_scale: {
      executor: "constant-vus",
      vus: 20,
      duration: "3m",
      exec: "employeeFlow",
      startTime: "0s",
      tags: { scenario: "current_scale" },
    },
    target_scale: {
      executor: "ramping-vus",
      startVUs: 20,
      stages: [
        { duration: "1m", target: 100 }, // ramp 20 -> 100
        { duration: "3m", target: 100 }, // hold at target scale
        { duration: "1m", target: 0 },   // ramp down
      ],
      exec: "employeeFlow",
      startTime: "3m", // starts right after current_scale ends
      tags: { scenario: "target_scale" },
    },
    admin_dashboard: {
      executor: "constant-vus",
      vus: Math.min(2, supervisors.length || 1),
      duration: "8m", // spans both scenarios above (3m + 1m + 3m + 1m = 8m)
      exec: "supervisorFlow",
      startTime: "0s",
      tags: { scenario: "admin_dashboard" },
    },
  },
  thresholds: {
    // These thresholds are deliberately strict — they're checking that a
    // 2 vCPU / 4 GB box stays responsive, not "is it technically up."
    "gps_ping_duration_ms": ["p(95)<500", "p(99)<1000"],
    "attendance_duration_ms": ["p(95)<500"],
    "team_live_duration_ms": ["p(95)<800"],
    "http_req_failed": ["rate<0.01"], // <1% hard failures (5xx/timeouts)
    "login_failures": ["count==0"],
  },
};

function authHeaders(token) {
  return { headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" } };
}

function login(email, password) {
  const res = http.post(
    `${API}/auth/login`,
    JSON.stringify({ email, password, client: "mobile" }),
    { headers: { "Content-Type": "application/json" }, tags: { name: "login" } }
  );
  const ok = check(res, { "login: 200": (r) => r.status === 200 });
  if (!ok) {
    loginFailures.add(1);
    return null;
  }
  return res.json("access_token");
}

// Per-VU in-memory session: login once, reuse for the VU's lifetime, and
// track where each VU is in the attendance state machine so transitions stay
// valid (START -> BREAK/RESUME -> END) instead of firing randomly into 409s.
const vuSessions = {};

function getSession(pool) {
  const key = `${__VU}`;
  if (!vuSessions[key]) {
    const creds = pool[(__VU - 1) % pool.length];
    const token = login(creds.email, creds.password);
    vuSessions[key] = { token, stage: "NONE", email: creds.email };
  }
  return vuSessions[key];
}

function jitter(base, spread) {
  return base + (Math.random() - 0.5) * spread;
}

export function employeeFlow() {
  const session = getSession(employees);
  if (!session.token) {
    sleep(2);
    return;
  }
  const headers = authHeaders(session.token);

  // ~12% of iterations: advance the attendance state machine one step.
  // ~88% of iterations: send a GPS batch (the dominant real-world traffic).
  if (Math.random() < 0.12) {
    const lat = jitter(12.9716, 0.05);
    const lng = jitter(77.5946, 0.05);
    let res, label;

    if (session.stage === "NONE" || session.stage === "ENDED") {
      res = http.post(`${API}/attendance/start`, JSON.stringify({ lat, lng }), {
        ...headers, tags: { name: "attendance_start" },
      });
      label = "start";
      if (res.status === 200) session.stage = "STARTED";
    } else if (session.stage === "STARTED" && Math.random() < 0.5) {
      res = http.post(`${API}/attendance/break`, JSON.stringify({ lat, lng }), {
        ...headers, tags: { name: "attendance_break" },
      });
      label = "break";
      if (res.status === 200) session.stage = "ON_BREAK";
    } else if (session.stage === "ON_BREAK") {
      res = http.post(`${API}/attendance/resume`, JSON.stringify({ lat, lng }), {
        ...headers, tags: { name: "attendance_resume" },
      });
      label = "resume";
      if (res.status === 200) session.stage = "STARTED";
    } else {
      res = http.post(
        `${API}/attendance/end`,
        JSON.stringify({ lat, lng, work_summary: "Load test synthetic shift." }),
        { ...headers, tags: { name: "attendance_end" } }
      );
      label = "end";
      if (res.status === 200) session.stage = "ENDED";
    }

    attendanceDuration.add(res.timings.duration);
    const ok = check(res, { [`attendance ${label}: 2xx`]: (r) => r.status >= 200 && r.status < 300 });
    if (!ok && res.status !== 409) businessErrors.add(1); // 409 = expected race on shared test data, not a bug
  } else {
    const now = new Date().toISOString();
    const records = [];
    const count = 1 + Math.floor(Math.random() * 3); // 1-3 points per batch, like a real offline-queue flush
    for (let i = 0; i < count; i++) {
      records.push({
        lat: jitter(12.9716, 0.05),
        lng: jitter(77.5946, 0.05),
        timestamp: now,
        accuracy: jitter(8, 4),
        speed: Math.random() * 5,
        battery_level: Math.floor(Math.random() * 100),
        is_mock_gps: false,
      });
    }
    const res = http.post(`${API}/location/batch`, JSON.stringify({ records }), {
      ...headers, tags: { name: "location_batch" },
    });
    gpsPingDuration.add(res.timings.duration);
    const ok = check(res, { "location batch: 200": (r) => r.status === 200 });
    if (!ok) businessErrors.add(1);
  }

  sleep(jitter(5, 5)); // 3-8s between iterations — see TIME COMPRESSION note above
}

export function supervisorFlow() {
  const session = getSession(supervisors.length ? supervisors : employees);
  if (!session.token) {
    sleep(2);
    return;
  }
  const headers = authHeaders(session.token);

  const res = http.get(`${API}/location/team-live`, { ...headers, tags: { name: "team_live" } });
  teamLiveDuration.add(res.timings.duration);
  check(res, { "team-live: 200": (r) => r.status === 200 });

  // Roughly once a minute, kick off a report — the heaviest single endpoint
  // (DB aggregation + file write). Worth watching CPU/memory during this.
  if (Math.random() < 0.05) {
    const today = new Date();
    const start = new Date(today);
    start.setDate(start.getDate() - 7);
    const body = {
      type: "TEAM",
      format: "EXCEL",
      filters: { month: today.toISOString().slice(0, 10) },
    };
    const res2 = http.post(`${API}/reports/generate`, JSON.stringify(body), {
      ...headers, tags: { name: "report_generate" },
    });
    reportGenDuration.add(res2.timings.duration);
    check(res2, { "report generate: 202": (r) => r.status === 202 });
  }

  sleep(jitter(10, 4)); // supervisors poll roughly every ~8-12s
}
