import Link from 'next/link';
import type { SiteSettings } from '@/lib/types';
import type { Tokens } from '@/lib/site';
import { Wordmark } from './Wordmark';
import { CookiePrefsButton } from './CookieBanner';

const SOCIAL: Record<string, string> = { instagram: 'Instagram', tiktok: 'TikTok', facebook: 'Facebook', x: 'X', youtube: 'YouTube', linkedin: 'LinkedIn' };
export const waLink = (e164: string) => `https://wa.me/${e164.replace(/\D/g, '')}`;

export function Footer({ s, t }: { s: SiteSettings; t: Tokens }) {
  const socials = Object.entries(s.social_links ?? {}).filter(([k, v]) => SOCIAL[k] && /^https:\/\//.test(v));
  return (
    <footer className="site-footer on-dark">
      <div className="wrap">
        <div className="footer-grid">
          <div className="footer-cta stack">
            {s.tagline && <p className="d3">{s.tagline}</p>}
            <p className="muted small measure">Car rental in {s.city}, picked up or delivered. Bring it back the way you got it, and so does your deposit.</p>
            <p><Link prefetch={false} className="btn btn--primary" href="/cars">Find a car</Link></p>
          </div>
          <nav aria-label="Rent"><h2>Rent</h2><ul>
            <li><Link prefetch={false} href="/cars">Fleet</Link></li><li><Link prefetch={false} href="/how-it-works">How it works</Link></li>
            <li><Link prefetch={false} href="/requirements">Requirements and coverage</Link></li><li><Link prefetch={false} href="/delivery">Delivery</Link></li>
            <li><Link prefetch={false} href="/book">Request to book</Link></li>
          </ul></nav>
          <div className="footer-contact"><h2>Talk to us</h2><ul>
            {s.phone && <li><a href={`tel:${s.phone}`}>{s.phone_display}</a><span>Phone and 24-hour roadside line</span></li>}
            {s.whatsapp && <li><a href={waLink(s.whatsapp)} rel="noopener">WhatsApp</a></li>}
            {s.public_email && <li><a href={`mailto:${s.public_email}`}>{s.public_email}</a></li>}
            <li><span>{[s.opening_hours_text, t.reply].filter(Boolean).join('. ')}.</span></li>
            {s.street_address && <li><span>{s.street_address}</span></li>}
          </ul></div>
          <nav aria-label="Company"><h2>{s.brand_name}</h2><ul>
            <li><Link prefetch={false} href="/list-your-car">List your car</Link></li><li><Link prefetch={false} href="/faq">FAQ</Link></li>
            <li><Link prefetch={false} href="/contact">Contact</Link></li><li><Link prefetch={false} href="/sign-in">Sign in</Link></li>
            {socials.map(([k, v]) => <li key={k}><a href={v} rel="noopener">{SOCIAL[k]}</a></li>)}
          </ul></nav>
          <nav aria-label="Legal"><h2>Legal</h2><ul>
            <li><Link prefetch={false} href="/terms">Terms of use</Link></li><li><Link prefetch={false} href="/privacy">Privacy policy</Link></li>
            <li><Link prefetch={false} href="/cancellation-policy">Cancellation policy</Link></li>
            <li><CookiePrefsButton /></li>
          </ul></nav>
        </div>
        <div className="footer-legal">
          <span>{s.brand_name}. {s.service_area}, Canada.</span>
          <span>Prices in Canadian dollars, before HST unless stated.</span>
          <Link prefetch={false} className="footer-investor" href="/investors">Investor sign in</Link>
        </div>
        <Wordmark s={s} className="wordmark--xl footer-mark" link={false} />
      </div>
    </footer>
  );
}
