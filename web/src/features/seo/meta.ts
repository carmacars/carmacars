import type { Metadata } from 'next';
import { getSettings, photoUrl, siteUrl } from '@/lib/site';

// Titles and descriptions come from the page's data (docs/blueprint/14-seo.md section 5). Every
// indexable page has a canonical address without query strings; filtered fleet views point to /cars.
export function pageMeta(o: { title: string; description: string; path: string; image?: string | null; noindex?: boolean; siteName?: string }): Metadata {
  const url = siteUrl() + (o.path === '/' ? '' : o.path);
  const image = o.image ?? `${siteUrl()}/og/default.png`;
  return {
    title: o.title, description: o.description,
    alternates: o.noindex ? undefined : { canonical: url },
    robots: o.noindex ? { index: false, follow: true } : undefined,
    openGraph: { title: o.title, description: o.description, url, type: 'website', locale: 'en_CA', ...(o.siteName ? { siteName: o.siteName } : {}), images: [{ url: image, width: 1200, height: 630 }] },
    twitter: { card: 'summary_large_image', title: o.title, description: o.description, images: [image] }
  };
}

// A page's openGraph replaces the layout's whole openGraph object, so the site name (from site settings) is
// added here for the public pages.
export async function seoMeta(o: Parameters<typeof pageMeta>[0]): Promise<Metadata> {
  const s = await getSettings();
  // the sharing image set in Admin > Settings, when there is one and the page has no photo of its own
  const og = s.og_image ? (/^https?:/.test(photoUrl(s.og_image)) ? photoUrl(s.og_image) : siteUrl() + photoUrl(s.og_image)) : null;
  return pageMeta({ ...o, image: o.image ?? og, siteName: s.brand_name });
}

export type Trail = [string, string?][];
export function breadcrumbLd(trail: Trail, path: string) {
  return { '@type': 'BreadcrumbList', itemListElement: trail.map(([name, href], i) => ({ '@type': 'ListItem', position: i + 1, name, item: siteUrl() + (href ?? path) })) };
}
export function faqLd(items: { question: string; answer: string }[]) {
  return { '@type': 'FAQPage', mainEntity: items.map((q) => ({ '@type': 'Question', name: q.question, acceptedAnswer: { '@type': 'Answer', text: q.answer.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() } })) };
}
