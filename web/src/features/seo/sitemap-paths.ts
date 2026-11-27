// The addresses of the site's own sitemap files that do not come from a database list (r50 hotfix 2). Pure, relative
// imports only (the unit test runs it in Node): src/features/seo/sitemap-paths.test.ts.
import { TRACKER_PATHS } from '../trackers/pages.ts';

// The sitemaps (docs/blueprint/14-seo.md section 9, migration 0061): the fixed pages of the pages file.
export const FIXED = ['/', '/cars', '/car-rental', '/guides', '/how-it-works', '/requirements', '/credit-card-rental-coverage', '/delivery', '/chauffeur', '/faq', '/contact', '/about', '/list-your-car', '/services', '/detailing', '/body-shop', '/partners/body-shops', '/partners/tow-trucks', '/place-data', '/places', '/makes', '/terms', '/privacy', '/cancellation-policy', '/gift-cards'];

/** The white-label software page for rental companies: indexable and in the pages file, linked from no menu. */
export const SOFTWARE_PATH = '/rental-software';

/** The pages file: the fixed pages, the tracker's own pages while the product is on (listed here, so a slow read of the
 *  families never leaves them out: /sitemap-families.xml answered an empty file and Search Console showed it with an
 *  error, Nov 26), the software page and the open roles. */
export function pagePaths(o: { trackers: boolean; careers: string[] }): string[] {
  return [...FIXED, ...(o.trackers ? TRACKER_PATHS : []), SOFTWARE_PATH, ...o.careers];
}

/** The families file: the database's list without the tracker's own pages (in the pages file: each address in one
 *  file), with the tracker's install pages of the places we reach. */
export function familiesOf<T extends { path: string; lastmod: string | null }>(fam: T[], places: Array<{ slug: string }>): Array<{ path: string; lastmod: string | null }> {
  return [...fam.filter((r) => !TRACKER_PATHS.includes(r.path)), ...places.map((x) => ({ path: `/trackers/install/${x.slug}`, lastmod: null }))];
}
