import type { MapsAdapter, Place, PlaceSuggestion } from './types';
import { fromComponents, fromLabel } from '../../features/forms/address-parts.ts';

// Google Maps Platform, called from the server only (the key never reaches the browser):
// Places API (New) Autocomplete and Place Details with one session token per lookup (billed as one
// session), and the Routes API for the driving distance from the company origin (the delivery fee).
// Plain fetch, so it runs unchanged in the Cloudflare Worker and is tested with a mocked fetch
// (google.test.ts). A failure answers like "not found": the forms fall back to typing the address and
// the booking request to "distance to be confirmed", never to an error page.
const PLACES = 'https://places.googleapis.com/v1';
const ROUTES = 'https://routes.googleapis.com/directions/v2:computeRoutes';
// Toronto: suggestions are biased to the service area and limited to Canada
const BIAS = { circle: { center: { latitude: 43.6532, longitude: -79.3832 }, radius: 50000 } };
const TIMEOUT_MS = 5000;

export interface GoogleMapsOptions { fetch?: typeof fetch; timeoutMs?: number }

export function googleMaps(apiKey: string, o: GoogleMapsOptions = {}): MapsAdapter {
  const f = o.fetch ?? ((...a: Parameters<typeof fetch>) => fetch(...a));
  const timeout = o.timeoutMs ?? TIMEOUT_MS;
  const headers = (fields: string) => ({ 'content-type': 'application/json', 'X-Goog-Api-Key': apiKey, 'X-Goog-FieldMask': fields });
  // A failed call still answers "not found", but says why in the Worker's log (Workers Observability), without the key:
  // a key without Places API (New) allowed, a referrer or IP restriction, billing off or a timeout (2026-10-24).
  async function call<T>(url: string, init: RequestInit): Promise<T | null> {
    const what = url.replace(/\?.*$/, '').replace(/^https:\/\/[^/]+/, '');
    try {
      const r = await f(url, { ...init, signal: AbortSignal.timeout(timeout) });
      if (!r.ok) {
        let why = '';
        try { const j = (await r.json()) as { error?: { status?: string; message?: string } }; why = [j.error?.status, j.error?.message].filter(Boolean).join(': '); } catch { /* not JSON */ }
        console.warn(`maps: Google ${what} answered ${r.status}${why ? ` (${why.slice(0, 300)})` : ''}`);
        return null;
      }
      return (await r.json()) as T;
    } catch (e) {
      console.warn(`maps: Google ${what} failed: ${e instanceof Error ? `${e.name} ${e.message}` : String(e)}`);
      return null;
    }
  }
  return {
    name: 'google',
    async autocomplete(query, sessionToken, o = {}): Promise<PlaceSuggestion[]> {
      const input = query.trim().slice(0, 120);
      if (input.length < 3) return [];
      const j = await call<{ suggestions?: { placePrediction?: { placeId: string; text?: { text?: string } } }[] }>(`${PLACES}/places:autocomplete`, {
        method: 'POST', headers: headers('suggestions.placePrediction.placeId,suggestions.placePrediction.text.text'),
        body: JSON.stringify({ input, sessionToken, ...(o.anywhere ? {} : { includedRegionCodes: ['ca'] }), languageCode: 'en', regionCode: 'ca', locationBias: BIAS })
      });
      return (j?.suggestions ?? [])
        .flatMap((s) => (s.placePrediction?.placeId && s.placePrediction.text?.text ? [{ id: s.placePrediction.placeId, label: s.placePrediction.text.text }] : []))
        .slice(0, 6);
    },
    async place(id, sessionToken): Promise<Place | null> {
      if (!/^[A-Za-z0-9_-]{4,300}$/.test(id)) return null;
      const q = new URLSearchParams({ sessionToken, languageCode: 'en', regionCode: 'ca' });
      // the address components are in the same (Essentials) field set: the form fills street, unit, city, province,
      // postal code and country from them (0130)
      const j = await call<{ id?: string; formattedAddress?: string; location?: { latitude?: number; longitude?: number }; addressComponents?: Array<{ longText?: string; shortText?: string; types?: string[] }> }>(
        `${PLACES}/places/${encodeURIComponent(id)}?${q}`, { headers: headers('id,formattedAddress,location,addressComponents') });
      const lat = j?.location?.latitude, lng = j?.location?.longitude;
      if (!j?.id || !j.formattedAddress || typeof lat !== 'number' || typeof lng !== 'number') return null;
      return { id: j.id, label: j.formattedAddress, lat, lng, parts: fromComponents(j.addressComponents) ?? fromLabel(j.formattedAddress) };
    },
    async distanceKm(from, to): Promise<number | null> {
      const point = (p: { lat: number; lng: number }) => ({ location: { latLng: { latitude: p.lat, longitude: p.lng } } });
      const j = await call<{ routes?: { distanceMeters?: number }[] }>(ROUTES, {
        method: 'POST', headers: headers('routes.distanceMeters'),
        body: JSON.stringify({ origin: point(from), destination: point(to), travelMode: 'DRIVE', routingPreference: 'TRAFFIC_UNAWARE', units: 'METRIC' })
      });
      const m = j?.routes?.[0]?.distanceMeters;
      return typeof m === 'number' && m >= 0 ? Math.round(m / 100) / 10 : null;
    }
  };
}
