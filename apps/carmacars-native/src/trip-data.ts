// A trip as the mobile API gives it (GET /trips/:number): the booking the site's own page reads (public.my_booking), its
// messages, and whether the renter checks in at the car themselves.
import type { Client } from './api/client.ts';
import type { TripLike } from './logic/trip.ts';

export interface Booking extends TripLike {
  id: string; vehicle_year: number; vehicle_make: string; vehicle_model: string; pickup_place: string | null; return_place: string | null; billable_days: number; total_due_at_booking_cents: number;
  renter_due_at_booking_cents: number; deposit_cents: number; coverage_option: number | null; offer_approved_version: number | null;
  offers: Array<{ version: number; status: string; expires_at: string | null; message: string | null; total_cents: number; renter_due_cents: number; deposit_cents: number; line_items: Array<{ label?: string; description?: string; amount_cents: number }> | null }>;
  payments: Array<{ id: string; purpose: string; amount_cents: number; status: string; card_brand: string | null; card_last4: string | null; created_at: string }>;
  extensions: Array<{ id: string; status: string; new_return_at: string; total_cents: number | null }>;
  documents: Array<{ id: string; title: string | null; kind: string }>;
  drivers: Array<{ driver_id: string; role: 'renter' | 'additional'; full_name: string }>;
  uploads: Array<{ id: string; driver_id: string | null; kind: 'licence_front' | 'licence_back' | 'selfie' | 'coverage_proof'; status: 'submitted' | 'approved' | 'rejected' | 'replaced'; reject_reason: string | null }>;
  still_needed?: TripLike['still_needed'];
}
export interface TripData { booking: Booking; messages: Array<{ id: string; direction: 'inbound' | 'outbound'; body: string; at: string; from: string }>; self_checkin: boolean }
export const loadTrip = (api: Client, number: string) => api.call('trip', { params: { number } }) as Promise<{ ok: true; data: TripData } | { ok: false; code: string; message: string }>;

