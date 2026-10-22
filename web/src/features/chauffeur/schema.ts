import { z } from '@/lib/zod';
import { email } from '@/features/forms/schemas';

// The chauffeur request (migration 0093): the form's schema, checked in the browser and again in the server action;
// the database checks everything once more (public.submit_chauffeur_request).
export const OCCASIONS = ['Airport transfer', 'Wedding', 'Night out', 'Business', 'Prom or graduation', 'Special event', 'Other'] as const;
export const chauffeurSchema = z.object({
  vehicle_id: z.string().uuid('Choose a vehicle.'),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the date.'),
  start_time: z.string().regex(/^\d{2}:\d{2}$/, 'Choose the start time.'),
  hours: z.coerce.number().int().min(2, 'Book at least 2 hours.').max(24, 'Book 24 hours at most.'),
  pickup_address: z.string().trim().min(3, 'Enter the pickup address.').max(300),
  dropoff_address: z.string().trim().max(300).optional().default(''),
  passengers: z.coerce.number().int().min(1, 'Enter the number of passengers.').max(20, 'Enter the number of passengers.'),
  occasion: z.string().trim().max(80).optional().default(''),
  notes: z.string().trim().max(2000, 'Keep it under 2,000 characters.').optional().default(''),
  name: z.string().trim().min(2, 'Enter your name.').max(120),
  email,
  phone: z.string().trim().refine((v) => v.replace(/\D/g, '').length >= 10, 'Enter a phone number with area code.').refine((v) => v.length <= 30, 'That number is too long.')
});
export type ChauffeurInput = z.infer<typeof chauffeurSchema>;

export interface ChauffeurVehicle {
  id: string; name: string; slug: string; kind: 'chauffeur_only' | 'chauffeur_rental'; passengers: number; active: boolean; sort_order: number;
  rate_2h_cents: number; rate_3plus_cents: number; rentals: Array<{ vehicle_id: string; name: string; path: string | null }>;
}
export interface ChauffeurServices { vehicles: ChauffeurVehicle[]; hst_bps: number; min_hours: number; max_hours: number }

/** The renter's price for a booking: 2 hours at the 2-hour rate, 3 or more at the 3+ hour rate, a hour (before HST). */
export const chauffeurPrice = (v: Pick<ChauffeurVehicle, 'rate_2h_cents' | 'rate_3plus_cents'>, hours: number) =>
  hours * (hours === 2 ? v.rate_2h_cents : v.rate_3plus_cents);
