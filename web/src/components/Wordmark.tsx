import Link from '@/components/Link';
import type { SiteSettings } from '@/lib/types';
import { photoUrl } from '@/lib/photo';

// The logo slot: the logo image from Admin > Settings > Site when one is uploaded (the dark-surface version on black),
// otherwise the brand logo of release 28 (public/brand: white letters on dark surfaces, black on light, the red bar on
// both). Fixed size from the SVG's own proportions, so it never shifts the header.
export const DEFAULT_LOGO = { dark: '/brand/carma-logo-white.svg', light: '/brand/carma-logo-black.svg', width: 857, height: 152 } as const;
function Mark({ s, dark }: { s: SiteSettings; dark: boolean }) {
  const img = (dark && s.logo.dark) || s.logo.light;
  const alt = s.logo.alt || s.brand_name;
  if (img) {
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={photoUrl(img)} width={s.logo.width ?? undefined} height={s.logo.height ?? undefined} alt={alt} />;
  }
  // eslint-disable-next-line @next/next/no-img-element
  return <img src={dark ? DEFAULT_LOGO.dark : DEFAULT_LOGO.light} width={DEFAULT_LOGO.width} height={DEFAULT_LOGO.height} alt={alt} decoding="async" />;
}

export function Wordmark({ s, className = '', link = true, dark = true }: { s: SiteSettings; className?: string; link?: boolean; dark?: boolean }) {
  if (link) return <Link prefetch={false} className={`wordmark ${className}`} href="/" aria-label={`${s.brand_name} home`}><Mark s={s} dark={dark} /></Link>;
  return <span className={`wordmark ${className}`} aria-hidden="true"><Mark s={s} dark={dark} /></span>;
}
