import 'server-only';
import { cache } from 'react';
import { rpc } from '@/lib/db/repo';

// The events behind /events (release 36, part 5; migration 2003).
export interface SeoEvent { slug: string; name: string; category: string; venue: string; venue_address: string | null; city: string; lat: number; lng: number; usual_months: string;
  starts_on: string | null; ends_on: string | null; summary: string; source_name: string; source_url: string; sort_order: number; updated_at: string }
export const getEvents = cache(async (): Promise<SeoEvent[]> => { try { return (((await rpc('seo_events_list', {})) ?? []) as unknown as SeoEvent[]); } catch { return []; } });
export const getEvent = cache(async (slug: string): Promise<SeoEvent | null> => {
  if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(slug)) return null;
  try { return ((await rpc('seo_event', { p_slug: slug })) ?? null) as unknown as SeoEvent | null; } catch { return null; }
});
