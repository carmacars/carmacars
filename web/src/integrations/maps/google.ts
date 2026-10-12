import 'server-only';
import type { MapsAdapter } from './types';

// Google Maps Platform, called from the server only (the key never reaches the browser):
// Places Autocomplete (New) and Place Details with one session token per lookup, Routes for distance.
export function googleMaps(apiKey: string): MapsAdapter {
  const headers = (fields: string) => ({ 'content-type': 'application/json', 'X-Goog-Api-Key': apiKey, 'X-Goog-FieldMask': fields });
  return {
    name: 'google',
    async autocomplete(query, sessionToken) {
      const r = await fetch('https://places.googleapis.com/v1/places:autocomplete', {
        method: 'POST', headers: headers('suggestions.placePrediction.placeId,suggestions.placePrediction.text'),
        body: JSON.stringify({ input: query, sessionToken, includedRegionCodes: ['ca'], locationBias: { circle: { center: { latitude: 43.6532, longitude: -79.3832 }, radius: 50000 } } })
      });
      if (!r.ok) return [];
      const j = (await r.json()) as { suggestions?: { placePrediction?: { placeId: string; text: { text: string } } }[] };
      return (j.suggestions ?? []).flatMap((s) => (s.placePrediction ? [{ id: s.placePrediction.placeId, label: s.placePrediction.text.text }] : [])).slice(0, 6);
    },
    async place(id, sessionToken) {
      const r = await fetch(`https://places.googleapis.com/v1/places/${encodeURIComponent(id)}?sessionToken=${encodeURIComponent(sessionToken)}`, { headers: headers('id,formattedAddress,location') });
      if (!r.ok) return null;
      const j = (await r.json()) as { id: string; formattedAddress: string; location: { latitude: number; longitude: number } };
      return { id: j.id, label: j.formattedAddress, lat: j.location.latitude, lng: j.location.longitude };
    },
    async distanceKm(from, to) {
      const r = await fetch('https://routes.googleapis.com/directions/v2:computeRoutes', {
        method: 'POST', headers: headers('routes.distanceMeters'),
        body: JSON.stringify({ origin: { location: { latLng: { latitude: from.lat, longitude: from.lng } } }, destination: { location: { latLng: { latitude: to.lat, longitude: to.lng } } }, travelMode: 'DRIVE' })
      });
      if (!r.ok) return null;
      const j = (await r.json()) as { routes?: { distanceMeters?: number }[] };
      const m = j.routes?.[0]?.distanceMeters;
      return typeof m === 'number' ? Math.round(m / 100) / 10 : null;
    }
  };
}
