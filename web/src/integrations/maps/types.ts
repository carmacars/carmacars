export interface PlaceSuggestion { id: string; label: string }
export interface Place { id: string; label: string; lat: number; lng: number }

export interface MapsAdapter {
  readonly name: 'google' | 'fake';
  /** Address suggestions while the person types, limited to Ontario. */
  autocomplete(query: string, sessionToken: string): Promise<PlaceSuggestion[]>;
  place(id: string, sessionToken: string): Promise<Place | null>;
  /** Driving distance in kilometres, or null when it cannot be worked out. */
  distanceKm(from: { lat: number; lng: number }, to: { lat: number; lng: number }): Promise<number | null>;
}
