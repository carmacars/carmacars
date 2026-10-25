export interface PlaceSuggestion { id: string; label: string }
import type { AddressParts } from '@/features/forms/address-parts';
export interface Place { id: string; label: string; lat: number; lng: number; /** the address in its parts (0130), when known */ parts?: AddressParts }

export interface SuggestOptions { /** every country, not only Canada (a staff member's home address abroad) */ anywhere?: boolean }

export interface MapsAdapter {
  readonly name: 'google' | 'fake';
  /** Address suggestions while the person types, in Canada and biased to Toronto (anywhere: every country). */
  autocomplete(query: string, sessionToken: string, o?: SuggestOptions): Promise<PlaceSuggestion[]>;
  /** The same, saying whether the daily cap stopped the lookup (0130: the form then says to type the address). */
  suggest?(query: string, sessionToken: string, o?: SuggestOptions): Promise<{ items: PlaceSuggestion[]; limited: boolean }>;
  place(id: string, sessionToken: string): Promise<Place | null>;
  /** Driving distance in kilometres, or null when it cannot be worked out. */
  distanceKm(from: { lat: number; lng: number }, to: { lat: number; lng: number }): Promise<number | null>;
}
