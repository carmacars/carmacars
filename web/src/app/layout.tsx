import type { Metadata, Viewport } from 'next';
import '@/styles/tokens.css';
import '@/styles/core.css';
import '@/styles/pages.css';
import { inter, interDisplay } from './fonts';
import { Header } from '@/components/Header';
import { Footer } from '@/components/Footer';
import { CookieBanner } from '@/components/CookieBanner';
import { Effects } from '@/components/Effects';
import { cookieWording, getSettings, getTokens, photoUrl, siteUrl } from '@/lib/site';

export async function generateMetadata(): Promise<Metadata> {
  const s = await getSettings();
  return {
    metadataBase: new URL(siteUrl()),
    title: { default: s.seo.default_title ?? `${s.brand_name} | ${s.city} car rental`, template: `%s` },
    description: s.seo.default_description ?? undefined,
    applicationName: s.brand_name,
    icons: { icon: s.favicon ? photoUrl(s.favicon) : '/favicon.svg' },
    openGraph: { siteName: s.brand_name, type: 'website', locale: 'en_CA' },
    twitter: { card: 'summary_large_image' }
  };
}

export const viewport: Viewport = { themeColor: '#000000', width: 'device-width', initialScale: 1 };

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const [s, t, w] = await Promise.all([getSettings(), getTokens(), cookieWording()]);
  return (
    <html lang="en-CA" className={`${interDisplay.variable} ${inter.variable}`}>
      <body>
        <CookieBanner w={w} />
        <Header s={s} />
        <main id="main" tabIndex={-1}>{children}</main>
        <Footer s={s} t={t} />
        <Effects />
      </body>
    </html>
  );
}
