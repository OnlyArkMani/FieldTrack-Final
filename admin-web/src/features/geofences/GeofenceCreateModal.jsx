import { useEffect, useMemo, useRef, useState } from 'react';
import {
  MapContainer,
  TileLayer,
  Circle,
  Polygon,
  Polyline,
  CircleMarker,
  useMap,
  useMapEvents,
} from 'react-leaflet';
import { Circle as CircleIcon, Hexagon, Search, MapPin } from 'lucide-react';

import { useCreateGeofence } from '@/hooks/useGeofences';
import { apiErrorMessage } from '@/services/api/client';
import Modal from '@/components/ui/Modal';
import Button from '@/components/ui/Button';
import { Input, Textarea } from '@/components/ui/Input';

const AMBER = '#F5A623';
const fill = { color: AMBER, fillColor: AMBER, fillOpacity: 0.2, weight: 2 };

const fmtRadius = (m) =>
  m >= 1000 ? `${(m / 1000).toFixed(m % 1000 === 0 ? 0 : 1)} km` : `${Math.round(m)} meters`;
const fmtArea = (sqm) =>
  sqm >= 1_000_000 ? `${(sqm / 1_000_000).toFixed(2)} km²` : `${Math.round(sqm).toLocaleString()} m²`;

/**
 * Bridges into the Leaflet map: handles flyTo on address-search select, and
 * map clicks (circle = set centre; polygon = add vertex, double-click closes).
 */
function MapBridge({ shape, flyTarget, onSetCenter, onAddVertex, onFinishPolygon }) {
  const map = useMap();
  const timer = useRef(null);

  useEffect(() => {
    if (flyTarget) map.flyTo(flyTarget, 16, { duration: 1.5 });
  }, [flyTarget, map]);

  useMapEvents({
    click(e) {
      const { lat, lng } = e.latlng;
      if (shape === 'CIRCLE') {
        onSetCenter([lat, lng]);
        return;
      }
      // polygon: debounce so the click preceding a dblclick doesn't add a point
      clearTimeout(timer.current);
      timer.current = setTimeout(() => onAddVertex([lat, lng]), 90);
    },
    dblclick() {
      if (shape === 'POLYGON') {
        clearTimeout(timer.current);
        onFinishPolygon();
      }
    },
  });
  return null;
}

export default function GeofenceCreateModal({ open, onClose, onCreated }) {
  const create = useCreateGeofence();

  const [shape, setShape] = useState(null); // 'CIRCLE' | 'POLYGON'
  const [center, setCenter] = useState(null); // [lat,lng]
  const [radius, setRadius] = useState(500);
  const [points, setPoints] = useState([]); // [[lat,lng], ...]
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [error, setError] = useState(null);

  // Address search (Nominatim)
  const [q, setQ] = useState('');
  const [results, setResults] = useState([]);
  const [searching, setSearching] = useState(false);
  const [flyTarget, setFlyTarget] = useState(null);

  useEffect(() => {
    if (!open) return;
    setShape(null);
    setCenter(null);
    setRadius(500);
    setPoints([]);
    setName('');
    setDescription('');
    setError(null);
    setQ('');
    setResults([]);
    setFlyTarget(null);
  }, [open]);

  // Debounced Nominatim lookup (free, no key; respects the 3-char minimum).
  useEffect(() => {
    if (q.trim().length < 3) {
      setResults([]);
      return undefined;
    }
    const t = setTimeout(async () => {
      setSearching(true);
      try {
        const r = await fetch(
          `https://nominatim.openstreetmap.org/search?q=${encodeURIComponent(
            q,
          )}&format=json&limit=5`,
          { headers: { Accept: 'application/json' } },
        );
        setResults(r.ok ? await r.json() : []);
      } catch {
        setResults([]);
      } finally {
        setSearching(false);
      }
    }, 400);
    return () => clearTimeout(t);
  }, [q]);

  const circleArea = useMemo(() => Math.PI * radius * radius, [radius]);

  const canCreate =
    name.trim().length >= 2 &&
    (shape === 'CIRCLE' ? !!center : points.length >= 3);

  const selectResult = (res) => {
    setFlyTarget([parseFloat(res.lat), parseFloat(res.lon)]);
    setQ(res.display_name);
    setResults([]);
  };

  const submit = async () => {
    setError(null);
    try {
      const base = { name: name.trim(), description: description.trim() || null };
      const body =
        shape === 'CIRCLE'
          ? {
              ...base,
              shape_type: 'CIRCLE',
              center_lat: center[0],
              center_lng: center[1],
              radius_meters: radius,
            }
          : {
              ...base,
              shape_type: 'POLYGON',
              coordinates: points.map(([lat, lng]) => [lng, lat]),
            };
      await create.mutateAsync(body);
      onCreated?.(shape === 'CIRCLE' ? center : points[0]);
      onClose();
    } catch (err) {
      setError(apiErrorMessage(err));
    }
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="New geofence"
      size="lg"
      footer={
        shape && (
          <>
            <Button variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button onClick={submit} loading={create.isPending} disabled={!canCreate}>
              Create geofence
            </Button>
          </>
        )
      }
    >
      {!shape ? (
        // ── Step 1: choose shape ───────────────────────────────────────
        <div>
          <p className="mb-4 text-sm text-text-secondary">Choose a zone shape:</p>
          <div className="grid grid-cols-2 gap-4">
            <ShapeCard
              icon={CircleIcon}
              label="Circle"
              hint="A centre point + radius"
              onClick={() => setShape('CIRCLE')}
            />
            <ShapeCard
              icon={Hexagon}
              label="Polygon"
              hint="Custom multi-point area"
              onClick={() => setShape('POLYGON')}
            />
          </div>
        </div>
      ) : (
        // ── Steps 2–4: locate, draw, name ──────────────────────────────
        <div className="space-y-4">
          {/* Address search */}
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-text-secondary" />
            <input
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="Search address or place…"
              className="h-10 w-full rounded-btn border border-border bg-surface pl-9 pr-3 text-sm text-text-primary placeholder:text-text-secondary focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/30"
            />
            {(results.length > 0 || searching) && (
              <div className="absolute z-[1000] mt-1 w-full overflow-hidden rounded-btn border border-border bg-card shadow-card">
                {searching && (
                  <div className="px-3 py-2 text-sm text-text-secondary">Searching…</div>
                )}
                {results.map((res) => (
                  <button
                    key={res.place_id}
                    onClick={() => selectResult(res)}
                    className="flex w-full items-start gap-2 px-3 py-2 text-left text-sm hover:bg-surface"
                  >
                    <MapPin className="mt-0.5 h-4 w-4 shrink-0 text-text-secondary" />
                    <span className="line-clamp-2 text-text-primary">{res.display_name}</span>
                  </button>
                ))}
              </div>
            )}
          </div>

          <p className="text-xs text-text-secondary">
            {shape === 'CIRCLE'
              ? center
                ? 'Centre set — adjust the radius below, or click again to move it.'
                : 'Click on the map to set the centre.'
              : 'Click to add points. Double-click to close the polygon.'}
          </p>

          {/* Map */}
          <div className="relative z-0 h-72 overflow-hidden rounded-card border border-border">
            <MapContainer
              center={[20.5937, 78.9629]}
              zoom={5}
              doubleClickZoom={shape !== 'POLYGON'}
              style={{ height: '100%', width: '100%' }}
            >
              <TileLayer
                url="https://tile.openstreetmap.org/{z}/{x}/{y}.png"
                attribution="&copy; OpenStreetMap contributors"
              />
              <MapBridge
                shape={shape}
                flyTarget={flyTarget}
                onSetCenter={setCenter}
                onAddVertex={(pt) => setPoints((p) => [...p, pt])}
                onFinishPolygon={() => {}}
              />
              {shape === 'CIRCLE' && center && (
                <>
                  <Circle center={center} radius={radius} pathOptions={fill} />
                  <CircleMarker center={center} radius={4} pathOptions={{ color: AMBER, fillColor: AMBER, fillOpacity: 1 }} />
                </>
              )}
              {shape === 'POLYGON' &&
                (points.length >= 3 ? (
                  <Polygon positions={points} pathOptions={fill} />
                ) : points.length >= 2 ? (
                  <Polyline positions={points} pathOptions={{ color: AMBER, weight: 2, dashArray: '6' }} />
                ) : null)}
              {shape === 'POLYGON' &&
                points.map((pt, i) => (
                  <CircleMarker key={i} center={pt} radius={4} pathOptions={{ color: AMBER, fillColor: '#fff', fillOpacity: 1 }} />
                ))}
            </MapContainer>
          </div>

          {/* Circle radius controls */}
          {shape === 'CIRCLE' && (
            <div>
              <div className="mb-1 flex items-center justify-between text-sm">
                <span className="font-medium text-text-primary">Radius</span>
                <span className="text-primary">{fmtRadius(radius)}</span>
              </div>
              <input
                type="range"
                min={50}
                max={10000}
                step={10}
                value={radius}
                onChange={(e) => setRadius(Number(e.target.value))}
                className="w-full accent-[var(--ft-primary)]"
                disabled={!center}
              />
              <p className="mt-1 text-xs text-text-secondary">
                Area ≈ {fmtArea(circleArea)}
              </p>
            </div>
          )}

          {/* Name + description */}
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} />
            <Input
              label="Description"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="Optional"
            />
          </div>

          {error && <p className="text-sm text-danger">{error}</p>}

          <button
            className="text-xs text-text-secondary hover:text-text-primary"
            onClick={() => {
              setShape(null);
              setCenter(null);
              setPoints([]);
            }}
          >
            ← Change shape
          </button>
        </div>
      )}
    </Modal>
  );
}

function ShapeCard({ icon: Icon, label, hint, onClick }) {
  return (
    <button
      onClick={onClick}
      className="flex flex-col items-center gap-2 rounded-card border-2 border-border p-6 transition-colors hover:border-primary hover:bg-primary/5"
    >
      <Icon className="h-10 w-10 text-primary" />
      <span className="text-base font-semibold text-text-primary">{label}</span>
      <span className="text-center text-xs text-text-secondary">{hint}</span>
    </button>
  );
}
