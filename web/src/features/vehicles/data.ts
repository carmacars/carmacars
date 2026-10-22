import 'server-only';
import type { Metadata } from 'next';
import { notFound, permanentRedirect } from 'next/navigation';
import { cache } from 'react';
import { seoMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { siteUrl } from '@/lib/site';
import type { Dim, Settings, TrimRef, Variant, YearRow } from './content';
import type { Inventory, SimilarModel } from './parts';
import type { TierPage, Tiers } from './deep';

// The vehicle pages' reads (migration 0092): one database call per page (public.vehicle_*_page), shared by the
// metadata and the page through React's cache. Unknown slugs are a 404; another spelling of a model answers 301.
type Named = { slug: string; name: string };
type Base = { path: string; inventory: Inventory; settings: Settings; indexable: boolean; canonical: string; lastmod: string | null; make: Named };
export type MakePage = Base & { level: 'make'; models: Array<{ slug: string; name: string; vclass: string | null; path: string; first_year: number; last_year: number; years: number;
  l100_min: number | null; kwh100_min: number | null; ev_range_max: number | null; fuels: string[]; trims: number }> };
export type ModelPage = Base & { level: 'model'; model: Named & { vclass: string | null }; in_catalog: boolean; years: YearRow[]; years_with_data: number; popular: boolean; body_group: string; similar_models: SimilarModel[] };
export type YearPage = Base & { level: 'year'; model: Named & { vclass: string | null }; year: number; vclass: string | null; variants: Variant[]; sources: string[]; body_group: string;
  trims: TrimRef[]; prev: { year: number; variants: Variant[]; trims: string[] } | null; next: { year: number } | null; other_years: YearRow[]; similar_models: SimilarModel[] };
export type TrimPage = Base & { level: 'trim'; model: Named & { vclass: string | null }; year: number; vclass: string | null; variants: Variant[]; sources: string[]; body_group: string; dims?: Dim[];
  trim: TrimRef & { source: string }; siblings: TrimRef[]; trim_years: Array<{ year: number; path: string }>;
  prev: { year: number; variants: Variant[]; trim_variant_ids: number[] | null } | null; other_years: YearRow[]; similar_models: SimilarModel[] };

const SLUG = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const ok = (...s: string[]) => s.every((x) => SLUG.test(x) && x.length <= 60);

export const makePage = cache(async (make: string): Promise<MakePage | null> => {
  if (!ok(make)) return null;
  return (await rpc('vehicle_make_page', { p_make: make })) as unknown as MakePage | null;
});
export const modelPage = cache(async (make: string, model: string): Promise<ModelPage> => {
  if (!ok(make, model)) notFound();
  const p = (await rpc('vehicle_model_page', { p_make: make, p_model: model })) as unknown as (ModelPage & { redirect?: string }) | null;
  if (!p) notFound();
  if (p.redirect) permanentRedirect(p.redirect);
  return p;
});
export const yearPage = cache(async (make: string, model: string, year: string): Promise<YearPage> => {
  if (!ok(make, model) || !/^(19|20)\d\d$/.test(year)) notFound();
  const p = (await rpc('vehicle_year_page', { p_make: make, p_model: model, p_year: Number(year) })) as unknown as YearPage | null;
  if (!p) notFound();
  return p;
});
export const trimPage = cache(async (make: string, model: string, year: string, trim: string): Promise<TrimPage> => {
  if (!ok(make, model, trim) || !/^(19|20)\d\d$/.test(year)) notFound();
  const p = (await rpc('vehicle_trim_page', { p_make: make, p_model: model, p_year: Number(year), p_trim: trim })) as unknown as TrimPage | null;
  if (!p) notFound();
  return p;
});

/** A city, city and colour, or colour page (0092): its trim's read with the city and colour. */
export const tierPage = cache(async (make: string, model: string, year: string, trim: string, city: string | null, colour: string | null): Promise<TierPage> => {
  if (!ok(make, model, trim) || !/^(19|20)\d\d$/.test(year) || (city !== null && !ok(city)) || (colour !== null && !/^[a-z]{3,12}$/.test(colour)) || city === 'colour') notFound();
  const p = (await rpc('vehicle_tier_page', { p_make: make, p_model: model, p_year: Number(year), p_trim: trim, p_place: city as string, p_colour: colour as string })) as unknown as TierPage | null;
  if (!p) notFound();
  return p;
});
/** The cities and colours a trim page links to. */
export const tiers = cache(async (): Promise<Tiers> => ((await rpc('vehicle_tiers', {})) as unknown as Tiers | null) ?? { settings: {}, places: [], place_count: 0, colours: [], terms: [] });

/** Metadata: the page's own canonical when it is indexed; noindex,follow with the canonical at the parent when not. */
export async function vehicleMeta(o: { title: string; description: string; path: string; indexable: boolean; canonical: string; image: string; imageAlt: string }): Promise<Metadata> {
  const m = await seoMeta({ title: o.title, description: o.description, path: o.path, image: siteUrl() + o.image, imageSize: [1800, 1200], imageAlt: o.imageAlt, noindex: !o.indexable });
  if (!o.indexable) m.alternates = { canonical: siteUrl() + o.canonical };
  return m;
}
