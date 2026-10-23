import { cache } from 'react';
import { rpc } from '@/lib/db/repo';
import type { CarRow } from '@/lib/types';
import type { Counts } from '@/features/seo/data';

// The public reads of migration 0095: one hub (a place and a term), the entry points, the service pages, the sitemaps.
export type Vertical = 'rental' | 'sale' | 'detailing' | 'bodyshop';
export interface PlaceBrief { slug: string; kind: 'country' | 'province' | 'region' | 'area' | 'city' | 'neighbourhood' | 'airport' | 'landmark'; name: string; country: 'CA' | 'US' | 'MX'; region: string | null; region_name: string | null }
export interface HubTerm { slug: string; vertical: Vertical; phrase: string; title: string; served: 'yes' | 'request'; landing_slug: string | null; lead_kind: string | null;
  service_code: string | null; intent_note: string; faq: Array<{ question: string; answer: string }>; canonical_path: string | null; landing_path: string | null }
export interface Hub {
  term: HubTerm; path: string;
  place: PlaceBrief & { lat: number | null; lng: number | null; gta: boolean; landing_slug: string | null; iata: string | null; sources: { geonames?: true; osm?: true; census?: true; fixture?: true } };
  ancestors: PlaceBrief[]; children: PlaceBrief[]; gta_members: PlaceBrief[] | null; nearby: Array<PlaceBrief & { km: number }>; landmarks: Array<{ name: string; km: number }>;
  airport: { name: string; iata: string | null; slug: string; km: number } | null; origin: { lat: number; lng: number; label: string };
  delivery: { in_reach: boolean; km: number | null; reach_km: number; fee_from_cents?: number | null; per_km_cents?: number };
  cars: CarRow[]; counts: Counts; real_cars: number | null; disclaimer: string | null;
  service: { code: string; name: string; description: string; from_price_cents: number | null } | null;
  related_terms: Array<{ slug: string; title: string; path: string }>; rental_terms: Array<{ slug: string; title: string; path: string }> | null;
  indexable: boolean; lastmod: string;
}
export interface ShopServices { services: Array<{ code: string; name: string; description: string; from_price_cents: number | null; terms: Array<{ slug: string; title: string }> }>; reach_km: number; origin: { label: string } }
export interface PlaceRoots { tops: PlaceBrief[]; cities: PlaceBrief[]; attribution: { geonames: boolean; osm: boolean } }

export const getHub = cache(async (vertical: Vertical, term: string, place: string) => (await rpc('place_hub', { p_vertical: vertical, p_term: term, p_place: place })) as unknown as Hub | null);
export const getPlaceRoots = cache(async () => ((await rpc('place_roots', {})) ?? { tops: [], cities: [], attribution: { geonames: false, osm: false } }) as unknown as PlaceRoots);
export const getShopServices = cache(async (vertical: 'detailing' | 'bodyshop') => (await rpc('shop_services_public', { p_vertical: vertical })) as unknown as ShopServices);

export const VERTICAL_ROOT: Record<Vertical, string> = { rental: '/car-rental', sale: '/buy', detailing: '/detailing', bodyshop: '/body-shop' };
/** The address of a hub (the same rule as app.place_hub_path in the database). */
export function hubPath(vertical: Vertical, term: string, place: string): string {
  if (vertical === 'rental' && term === 'car-rental') return `/car-rental/${place}`;
  return `${VERTICAL_ROOT[vertical]}/${term}/${place}`;
}

export interface TermRow { slug: string; vertical: Vertical; phrase: string; title: string; landing_slug: string | null; service_code: string | null; lead_kind?: string | null }
export const getTerms = cache(async () => ((await rpc('place_terms_public', {})) ?? []) as unknown as TermRow[]);
/** The slugs among these that are places with pages (a landing page links to its place pages only once the place is loaded). */
export const placesKnown = cache(async (slugs: string[]) => (slugs.length ? (((await rpc('places_known', { p_slugs: slugs })) ?? []) as unknown as string[]) : []));
