import type { Metadata, Viewport } from 'next';
import '@/styles/tokens.css';
import '@/styles/core.css';
import '@/styles/pages.css';
import '@/styles/app.css';
import '@/styles/motion.css';
import '@/portable/motion/tokens.css';
import '@/portable/motion/motion.css';
import '@/portable/motion/design.css';
import '@/styles/motion-kit.css';
import { inter, interDisplay } from './fonts';
import { Header } from '@/components/Header';
import { Footer } from '@/components/Footer';
import { CookieBanner } from '@/components/CookieBanner';
import { Effects } from '@/components/Effects';
import { MotionRuntime } from '@/portable/motion/react';
import { MOTION_PAUSE_SCRIPT } from '@/portable/motion/runtime';
import { CHUNK_GUARD_SCRIPT } from '@/lib/chunk-guard';
import { DOM_GUARD_SCRIPT } from '@/lib/client-error/dom-guard';
import { ViewAsBanner } from '@/features/access/ViewAsBanner';
import { SiteAssist } from '@/features/live/SiteAssist';
import { JsonLd } from '@/components/JsonLd';
import { AppShellMount } from '@/features/app-shell/AppShellMount';
import { SHELL_MARK_SCRIPT } from '@/lib/native/shell';
import { businessLd, websiteLd } from '@/features/seo/business';
import { getHubLinks, getSeoLinks } from '@/features/seo/data';
import { cookieWording, getSettings, photoUrl, replyText, siteUrl, appLinks } from '@/lib/site';
import { ClientErrorListener } from '@/lib/client-error/Listener';

import { FormGuard } from '@/components/FormGuard';
import { openRoles } from '@/server/careers';
import { metaOr } from '@/features/seo/meta-fallback';

// r47: metadata streams to browsers after the page; a failed settings read here gave React #441 on every page's
// navigation (features/seo/meta-fallback.ts), so it falls back to the site's plain metadata
export async function generateMetadata(): Promise<Metadata> {
  return metaOr(rootMetadata, { metadataBase: new URL(siteUrl()), title: { default: 'CarmaCars', template: '%s' }, manifest: '/manifest.webmanifest' },
    (m) => console.warn('root', m));
}
async function rootMetadata(): Promise<Metadata> {
  const s = await getSettings();
  return {
    metadataBase: new URL(siteUrl()),
    title: { default: s.seo.default_title ?? `${s.brand_name} | ${s.city} car rental`, template: `%s` },
    description: s.seo.default_description ?? undefined,
    applicationName: s.brand_name,
    // release 28: the brand kit's favicons (public/favicon.*) unless Admin uploaded one
    icons: { icon: s.favicon ? photoUrl(s.favicon) : [{ url: '/favicon.ico', sizes: 'any' }, { url: '/favicon.svg', type: 'image/svg+xml' }, { url: '/favicon-32.png', sizes: '32x32', type: 'image/png' }],
      apple: [{ url: '/icons/apple-touch-icon.png', sizes: '180x180' }] },
    // installable on phones (migration 0300): the manifest, and iOS's Home Screen name and full-screen mode
    manifest: '/manifest.webmanifest',
    appleWebApp: { capable: true, title: s.brand_name, statusBarStyle: 'black' },
    openGraph: { siteName: s.brand_name, type: 'website', locale: 'en_CA' },
    twitter: { card: 'summary_large_image' },
    // Search Console and Bing Webmaster Tools (Admin > Settings > Site, 0061)
    verification: { ...(s.google_site_verification ? { google: s.google_site_verification } : {}),
      ...(s.bing_site_verification ? { other: { 'msvalidate.01': s.bing_site_verification } } : {}) }
  };
}

export const viewport: Viewport = { themeColor: '#0A0A0A', width: 'device-width', initialScale: 1 };

// the brand's tab bars, dashboard figures, lists and save statuses for the motion kit
const MOTION_HOOKS = {
  tabs: '.ui-tabs, .ad-tabs, .bk-tabs, .vs-tabs, .ph-tabs, .sp-tabs',
  counters: '.pu-stat__value, .ow-amount, .pt-total, .fd-big',
  // public lists only: the Admin's daily rows get no entrance (frequency of use: the more often, the less motion)
  lists: '.fleet-grid',
  statuses: '.pa__saved, .ok',
  carousels: '.rail, .gallery__track'
};

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  // settings and the cookie wording only: the frame runs on every page (docs/audit/2026-10-13-launch-audit.md section 9)
  const [s, w, links, hubs, roles, apps] = await Promise.all([getSettings(), cookieWording(), getSeoLinks().catch(() => []), getHubLinks(), openRoles(), appLinks()]);
  return (
    <html lang="en-CA" className={`${interDisplay.variable} ${inter.variable}`} suppressHydrationWarning>
      {/* the stale page guard: a script or stylesheet of an older build that fails to load reloads the page once (src/lib/chunk-guard.ts) */}
      <head><script id="chunk-guard" dangerouslySetInnerHTML={{ __html: CHUNK_GUARD_SCRIPT }} />
        {/* r47: a page the browser translated never crashes on React's next change (src/lib/client-error/dom-guard.ts) */}
        <script id="dom-guard" dangerouslySetInnerHTML={{ __html: DOM_GUARD_SCRIPT }} />
        {/* r48 AN: the pause control's remembered choice (WCAG 2.2.2) before the first paint (src/portable/motion) */}
        <script id="motion-pause" dangerouslySetInnerHTML={{ __html: MOTION_PAUSE_SCRIPT }} />
        {/* r27b: the phone and email the error page shows (src/lib/client-error/ErrorPanel.tsx), from Site settings */}
        <meta name="cc-contact" content={JSON.stringify({ phone: s.phone_display || s.phone, email: s.public_email })} /></head>
      <body>
        {/* the store app (0390): <html data-shell="app"> before the first paint, so web-only parts never flash */}
        <script dangerouslySetInnerHTML={{ __html: SHELL_MARK_SCRIPT }} />
        <ViewAsBanner />
        <CookieBanner w={w} />
        <Header s={s} />
        <main id="main" tabIndex={-1}>{children}</main>
        <Footer s={s} reply={replyText(s)} links={links} hubs={hubs} careers={roles.length > 0} apps={apps} />
        {/* the business on every page (settings only), so every #business reference resolves (2026-10-23-ai-search) */}
        <JsonLd graph={[websiteLd(s, siteUrl()), businessLd(s, siteUrl(), { lite: true })]} />
        <Effects />
        {/* r48 AN: the micro-interactions of every page and portal (src/portable/motion; CarmaCars' hooks below) */}
        <MotionRuntime hooks={MOTION_HOOKS} />
        <SiteAssist />
        <AppShellMount />
        <ClientErrorListener />
        <FormGuard />
      </body>
    </html>
  );
}
