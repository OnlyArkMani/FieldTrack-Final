# FieldTrack Monitoring Stack

Start it alongside the main stack (run from `/opt/fieldtrack/app`):

```bash
docker compose -f docker-compose.prod.yml -f monitoring/docker-compose.monitoring.yml up -d
```

## What's in here

**Uptime Kuma** (`/status`) — a simple uptime monitor with a public status
page. After it starts, open `https://your-domain.com/status/`, create an
admin account on first visit, then add a monitor:
- Type: HTTP(s)
- URL: `https://your-domain.com/api/v1/health`
- Heartbeat interval: 60s

Uptime Kuma can also send its own notifications (Telegram, Discord, email,
etc.) on outage — independent of Grafana, useful as a second opinion if
Grafana itself is down.

**Prometheus** (internal only, not exposed via Nginx) — scrapes:
- `app:8000/metrics` every 15s for request count, latency, and error rate
  (added via `prometheus-fastapi-instrumentator`, already wired into
  `app/main.py`).
- `node-exporter:9100/metrics` for VPS-level CPU, memory, and disk.

If you need to query Prometheus directly, SSH-tunnel rather than exposing it:

```bash
ssh -L 9090:localhost:9090 deploy@your-vps
# then open http://localhost:9090 in your local browser
```

**Grafana** (`/grafana`) — log in with `admin` / the
`GRAFANA_ADMIN_PASSWORD` from `.env.prod`. Change it on first login.

### Adding the Prometheus data source

1. Configuration -> Data sources -> Add data source -> Prometheus
2. URL: `http://prometheus:9090` (container name, internal network)
3. Save & test

### Building a dashboard

Easiest path: Dashboards -> New -> Import -> paste dashboard ID `14282`
(FastAPI Observability) from grafana.com, select the Prometheus data source.
This gives you request rate, latency percentiles, and error rate panels out
of the box. Add a second imported dashboard, ID `1860` (Node Exporter Full),
for VPS-level CPU/memory/disk.

### Alerts to configure

Grafana Alerting -> Alert rules -> New alert rule. Three to set up first:

1. **Response time > 2s**
   Query: 95th percentile of `http_request_duration_seconds` (from the
   FastAPI dashboard) over a 5-minute window. Condition: `> 2`. This catches
   slow queries or an overloaded app before users notice widespread
   timeouts.

2. **Error rate > 5%**
   Query: ratio of `http_requests_total{status=~"5.."}` to total
   `http_requests_total` over 5 minutes. Condition: `> 0.05`. Catches
   crashes, bad deploys, or a downstream dependency (Postgres/Redis) being
   unreachable.

3. **Disk usage > 80%**
   Query: `node_filesystem_avail_bytes / node_filesystem_size_bytes` for the
   root filesystem. Condition: `< 0.20` (i.e. less than 20% free). A full
   disk on a 2 vCPU/4GB VPS will silently break Postgres writes and Docker
   image pulls — this gives you time to prune images or grow the volume
   before that happens.

### Email alerts

Alerting -> Contact points -> New contact point -> type "Email". Grafana
needs outbound SMTP credentials to send mail — add these to `.env.prod` and
pass them through as extra `GF_SMTP_*` environment variables on the `grafana`
service (e.g. `GF_SMTP_ENABLED=true`, `GF_SMTP_HOST`, `GF_SMTP_USER`,
`GF_SMTP_PASSWORD`, `GF_SMTP_FROM_ADDRESS`). Any SMTP provider works — Gmail
with an app password, SendGrid, Mailgun, etc. After adding the contact point,
attach it to a Notification Policy so the three alert rules above route to
it.
