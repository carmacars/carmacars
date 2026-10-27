import type { NextConfig } from 'next';
import { initOpenNextCloudflareForDev } from '@opennextjs/cloudflare';

const EMAIL_PATHS: Array<[string, string]> = [
  ['/account/bookings/:n/request', '/account/bookings/:n#questions'], ['/account/bookings/:n/agreement', '/account/bookings/:n/sign'],
  // (condition-report is a page since 0130: the renter's photo report)
  ['/account/bookings/:n/pickup', '/account/bookings/:n'],
  ['/account/bookings/:n/return', '/account/bookings/:n'], ['/account/bookings/:n/statement', '/account/bookings/:n'],
  ['/account/bookings/:n/incident', '/account/bookings/:n'],
  ['/owner/application', '/owner'], ['/owner/agreements', '/owner/documents'], ['/owner/billing', '/owner/invoices'],
  ['/owner/vehicles/:id/onboarding', '/owner/vehicles/:id'], ['/owner/vehicles/:id/calendar', '/owner/bookings'], ['/owner/vehicles/:id/exit', '/owner/vehicles/:id'],
  ['/owner/bookings/:n', '/owner/bookings'], ['/owner/claims/:n', '/owner/notifications'],
  ['/admin/approvals', '/admin/tasks'], ['/admin/disputes/:id', '/admin/money?tab=disputes'], ['/admin/fleet', '/admin/vehicles'], ['/admin/jobs', '/admin'],
  ['/admin/reports/weekly', '/admin/reports'],
  ['/va/cs/bookings/:n/identity', '/va/verify/:n'], ['/va/:fn(cs|finance|fleet|sales)/bookings/:n', '/va/bookings/:n'],
  ['/va/finance/tolls-tickets/:id', '/va/tolls'], ['/va/finance/owner-invoices/:n', '/va/money'], ['/va/finance/insurer-invoices/:n', '/va/money'],
  ['/va/finance/turo', '/va/turo'], ['/va/finance/reconciliation', '/va/reconciliation'],
  ['/va/fleet/listings/:id', '/va/listings'], ['/va/fleet/expiries', '/va/fleet#expiry'], ['/va/fleet/vehicles/:id', '/va/vehicles/:id'], ['/va/fleet/checks', '/va/checks'],
  ['/va/sales/applications/:id', '/va/leads'], ['/va/sales/quotes/new', '/va/quotes/new'], ['/va/cs/reviews', '/va'],
  ['/va/:fn(cs|finance|sales)', '/va']
];

const config: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  typedRoutes: false,
  // Images come pre-sized from the photo pipeline (docs/blueprint/09-listing-pipeline.md); no runtime
  // resizing in the Worker.
  images: { unoptimized: true },
  // The styles go inside the page instead of a separate file the browser must fetch before it paints (0095 speed: the
  // render-blocking stylesheet request was the longest chain before the hero image on a phone).
  // Server actions take uploads up to 15 MB (the default is 1 MB): the Blind Spot blank agreement and the official
  // ServiceOntario forms are 2 to 3 MB PDFs, and an upload above the limit failed the whole page.
  experimental: { inlineCss: true, serverActions: { bodySizeLimit: '15mb' } },
  env: {
    NEXT_PUBLIC_DATA_BACKEND: process.env.DATA_BACKEND ?? 'local',
    NEXT_PUBLIC_TURNSTILE_PROVIDER: process.env.TURNSTILE_PROVIDER ?? 'fake'
  },
  // Server-only packages resolved from node_modules instead of being compiled into every route layer's
  // chunks: the Worker bundle (OpenNext, then wrangler) then holds one copy of each instead of two or three
  // (pdf-lib, zod and supabase-js were each bundled per layer; web/README.md, Worker size).
  serverExternalPackages: ['postgres', 'pdf-lib', 'zod', '@supabase/supabase-js', '@supabase/ssr', 'jose', 'aws4fetch'],
  async headers() {
    const noindex = [{ key: 'X-Robots-Tag', value: 'noindex, nofollow' }];
    return [
      { source: '/account/:path*', headers: noindex },
      { source: '/book/:path*', headers: noindex },
      { source: '/api/:path*', headers: noindex },
      ...['/admin', '/owner', '/va', '/field', '/investor', '/two-step', '/files', '/d', '/sign', '/unsubscribe'].flatMap((p) => [{ source: p, headers: noindex }, { source: `${p}/:path*`, headers: noindex }]),
      ...(process.env.APP_ENV === 'staging' ? [{ source: '/:path*', headers: noindex }] : [])
    ];
  },
  // the files search engines ask for at the root (0061): the IndexNow key file and the Google verification file
  // 0124: every sitemap at the site's root (a sitemap index may list only files in its own directory or below; a sitemap
  // outside Search Console covers only its own directory): /sitemap-index-<n>.xml, /sitemap-priority-<n>.xml,
  // /sitemap-vehicles-<file>.xml and /sitemap-places-<file>.xml, answered by the handlers under /sitemap-files/.
  async rewrites() {
    return {
      beforeFiles: [
        { source: '/:name(sitemap-index-\\d{1,5}\\.xml)', destination: '/sitemap-files/index/:name' },
        { source: '/:name(sitemap-priority-\\d{1,3}\\.xml)', destination: '/sitemap-files/priority/:name' },
        { source: '/:name(sitemap-vehicles-[a-z0-9-]{1,120}\\.xml)', destination: '/sitemap-files/vehicles/:name' },
        { source: '/:name(sitemap-places-[a-z0-9.-]{1,160}\\.xml)', destination: '/sitemap-files/places/:name' }
      ],
      afterFiles: [
        { source: '/:name([a-f0-9]{32}\\.txt)', destination: '/api/site-file/:name' },
        { source: '/:name(google[a-z0-9]{6,40}\\.html)', destination: '/api/site-file/:name' }
      ],
      fallback: []
    };
  },
  async redirects() {
    // The prototype's file names, in case one was shared.
    return [
      { source: '/fleet.html', destination: '/cars', permanent: true },
      { source: '/owners.html', destination: '/list-your-car', permanent: true },
      { source: '/signin.html', destination: '/sign-in', permanent: true },
      { source: '/sign-up', destination: '/create-account', permanent: true },
      // the unsubscribe link's first path (0018); marketing links now go to /unsubscribe (0034)
      { source: '/email/unsubscribe', destination: '/unsubscribe', permanent: true },
      // Paths the emails link to (emails/src/links.mjs) that are sections of a page here, or the blueprint's
      // longer names for the assistants' screens: each goes to the page that holds it (sign-in first where needed).
      ...EMAIL_PATHS.map(([source, destination]) => ({ source, destination, permanent: false }))
    ];
  }
};

if (process.env.NODE_ENV === 'development' && process.env.DATA_BACKEND === 'supabase') initOpenNextCloudflareForDev();

export default config;
