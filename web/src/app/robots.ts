import type { MetadataRoute } from 'next';
import { env } from '@/lib/env';
import { siteUrl } from '@/lib/site';

// docs/blueprint/14-seo.md section 10. Staging is closed to crawlers. Query strings on the public pages are views
// for people (filters, dates); the clean address is the one to index.
export default function robots(): MetadataRoute.Robots {
  if (env().APP_ENV === 'staging') return { rules: [{ userAgent: '*', disallow: '/' }] };
  return {
    rules: [{ userAgent: '*', allow: '/', disallow: ['/book', '/account', '/owner', '/investor', '/admin', '/va', '/field', '/go/', '/r/', '/unsubscribe', '/email/', '/files/', '/d/', '/sign/', '/sign-document/', '/guide-pdf/', '/sign-in', '/create-account', '/reset-password', '/update-password', '/two-step', '/choose-portal', '/read-only', '/link-expired', '/api/', '/cars?', '/cars/*?', '/car-rental/*?', '/guides/*?', '/rent/*?'] }],
    sitemap: `${siteUrl()}/sitemap.xml`
  };
}
