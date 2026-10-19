import { cache } from 'react';
import { rpc } from '@/lib/db/repo';
import type { CarRow } from '@/lib/types';
import type { Faq } from './copy';

// The public reads of migration 0061: landing pages, articles and the footer's links.
export interface SeoLink { slug: string; kind: 'location' | 'use'; name: string; path: string }
export interface Counts { car_count: number; real_cars: number; min_daily_cents: number | null; min_weekly_cents: number | null; min_monthly_cents: number | null; min_delivery_cents: number | null }
export interface SeoPageRow extends SeoLink, Counts { h1: string; summary: string; indexable: boolean; lastmod: string }
export interface SeoPage extends SeoLink, Counts {
  copy: { seo_title: string; meta_description: string; h1: string; intro: string; sections: Array<{ heading: string; body: string }>; faq: Faq[] };
  facts: Record<string, unknown>; indexable: boolean; lastmod: string; cars: CarRow[];
  airport: { code: string; name: string; surcharge_cents: number | null } | null; delivery_per_km_cents: number; distance_km: number | null;
  nearby: SeoLink[]; other: SeoLink[];
}
export interface ArticleRow { slug: string; title: string; description: string; summary: string | null; topic: string | null; path: string; published_at: string; updated_at: string }
export interface Article extends ArticleRow { seo_title: string | null; body_md: string; faq: Faq[]; links: Array<{ href: string; label: string }>; author_name: string | null; related: Array<{ slug: string; title: string; path: string }> }

export const getSeoLinks = cache(async () => ((await rpc('seo_links', {})) ?? []) as unknown as SeoLink[]);
export const getSeoPages = cache(async () => ((await rpc('seo_pages_public', {})) ?? []) as unknown as SeoPageRow[]);
export const getSeoPage = cache(async (slug: string) => (await rpc('seo_page', { p_slug: slug })) as unknown as SeoPage | null);
export const getArticles = cache(async () => ((await rpc('articles_public', {})) ?? []) as unknown as ArticleRow[]);
export const getArticle = cache(async (slug: string) => (await rpc('article', { p_slug: slug })) as unknown as Article | null);

/** Paragraphs of a copy field (blank lines between them). */
export const paras = (s: string) => s.split(/\n{2,}/).map((x) => x.trim()).filter(Boolean);
