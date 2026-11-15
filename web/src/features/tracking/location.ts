import { ago } from './model.ts';

// Release 48 (3041): one car's location, as every staff member sees it on the car and booking pages
// (app.tracker_car) and as its owner sees it on the owner portal (app.owner_car_location: the location and the trips, never
// a booking or a renter). Pure: the words and the map links (unit tested).
export interface CarPos { lat: number; lng: number; at: string; speed: number | null; ignition: boolean | null; moving: boolean }
export interface CarLoc { vehicle_id: string; name: string; tracker: boolean; pos: CarPos | null }
export interface OwnerTrip { id: string; started_at: string; ended_at: string; km: number; from: { lat: number; lng: number } | null; to: { lat: number; lng: number } | null }
export interface OwnerLoc extends CarLoc { days: number; trips: OwnerTrip[] }

export const NO_TRACKER = 'No tracker yet';

/** A point on the public map (OpenStreetMap), opened in a new tab. */
export const mapLink = (p: { lat: number; lng: number }) =>
  `https://www.openstreetmap.org/?mlat=${p.lat.toFixed(5)}&mlon=${p.lng.toFixed(5)}#map=16/${p.lat.toFixed(5)}/${p.lng.toFixed(5)}`;

/** The state in a few words: no tracker, not reported yet, moving (with the speed) or parked, and how long ago. */
export function locationLine(d: CarLoc, now: number): string {
  if (!d.tracker) return `${NO_TRACKER}.`;
  if (!d.pos) return 'The tracker has not reported a position yet.';
  const a = ago(d.pos.at, now);
  const seen = a === 'now' ? 'just now' : `${a} ago`;
  return d.pos.moving ? `Moving at ${Math.round(d.pos.speed ?? 0)} km/h, seen ${seen}.` : `Parked, last seen ${seen}.`;
}
