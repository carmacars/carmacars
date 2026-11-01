import type { Car } from './model';

// What app.booking_cards (migration 0332) adds to a row of Requests and offers or All bookings.
export interface Card {
  car: Car; phone: string | null; licence: 'verified' | 'pending' | 'missing'; bill_to: 'renter' | 'insurer' | 'split' | null; placeholder: boolean; expired_at?: string | null;
  money: { state: 'paid' | 'overdue' | 'soon' | 'upcoming' | 'none'; plan: string; open_cents: number; next_cents: number | null; next_at: string | null } | null;
}
export type Cards = Record<string, Card>;
