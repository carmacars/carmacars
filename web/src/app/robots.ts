import type { MetadataRoute } from 'next';
import { env } from '@/lib/env';
import { siteUrl } from '@/lib/site';

// docs/blueprint/14-seo.md section 10. Staging is closed to crawlers.
export default function robots(): MetadataRoute.Robots {
  if (env().APP_ENV === 'staging') return { rules: [{ userAgent: '*', disallow: '/' }] };
  return {
    rules: [{ userAgent: '*', allow: '/', disallow: ['/book', '/account', '/owner', '/investor', '/admin', '/va', '/field', '/go/', '/r/', '/unsubscribe', '/email/', '/files/', '/d/', '/sign/', '/sign-in', '/create-account', '/reset-password', '/update-password', '/two-step', '/api/', '/cars?', '/cars/*?'] }],
    sitemap: `${siteUrl()}/sitemap.xml`
  };
}
