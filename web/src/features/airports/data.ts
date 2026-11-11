import 'server-only';
import { cache } from 'react';
import { rpc } from '@/lib/db/repo';

// The airport pages (release 36, part 10; migration 2003): each active airport with the lowest standard delivery price
// to its terminal (app.delivery_fee of each car on the site, no special offer).
export interface AirportPage { code: string; name: string; lat: number; lng: number; km: number | null; delivery_from_cents: number | null }
export const getAirports = cache(async (): Promise<AirportPage[]> => { try { return (((await rpc('airport_pages', {})) ?? []) as unknown as AirportPage[]); } catch { return []; } });
export const getAirport = cache(async (code: string): Promise<AirportPage | null> => (/^[a-z0-9]{3,4}$/.test(code) ? (await getAirports()).find((a) => a.code.toLowerCase() === code) ?? null : null));
