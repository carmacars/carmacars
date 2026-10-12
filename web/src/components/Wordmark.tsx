import Link from 'next/link';
import type { SiteSettings } from '@/lib/types';
import { photoUrl } from '@/lib/photo';

// The logo slot: the logo image from site settings when one is set (the dark-surface version on
// black), otherwise the text wordmark "Carma" + red "Cars".
function Mark({ s, dark }: { s: SiteSettings; dark: boolean }) {
  const img = (dark && s.logo.dark) || s.logo.light;
  if (img) {
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={photoUrl(img)} width={s.logo.width ?? undefined} height={s.logo.height ?? undefined} alt={s.logo.alt} />;
  }
  const w = s.logo.wordmark || s.brand_name;
  const i = w.search(/(?<=.)[A-Z]/);
  return i > 0 ? <>{w.slice(0, i)}<b>{w.slice(i)}</b></> : <>{w}</>;
}

export function Wordmark({ s, className = '', link = true, dark = true }: { s: SiteSettings; className?: string; link?: boolean; dark?: boolean }) {
  if (link) return <Link className={`wordmark ${className}`} href="/" aria-label={`${s.brand_name} home`}><Mark s={s} dark={dark} /></Link>;
  return <span className={`wordmark ${className}`} aria-hidden="true"><Mark s={s} dark={dark} /></span>;
}
