import Link from 'next/link';
import type { SiteSettings } from '@/lib/types';
import { Wordmark } from './Wordmark';
import { CookiePrefsButton } from './CookieBanner';
import { napAddress } from '@/features/seo/business';
import { PortalSwitchFooter } from './HeaderClient';
import type { HubLinks } from '@/features/seo/data';

const SOCIAL: Record<string, string> = { instagram: 'Instagram', tiktok: 'TikTok', facebook: 'Facebook', x: 'X', youtube: 'YouTube', linkedin: 'LinkedIn' };
export const waLink = (e164: string) => `https://wa.me/${e164.replace(/\D/g, '')}`;

type Link_ = { slug: string; kind: string; name: string; path: string };
export function Footer({ s, reply, links = [], hubs }: { s: SiteSettings; reply: string; links?: Link_[]; hubs?: HubLinks }) {
  const places = links.filter((l) => l.kind === 'location');
  const uses = links.filter((l) => l.kind === 'use');
  const socials = Object.entries(s.social_links ?? {}).filter(([k, v]) => SOCIAL[k] && /^https:\/\//.test(v));
  // inside a portal: one short line (contact, the public site, the legal pages) instead of the site's long footer
  const compact = (
    <footer className="site-footer site-footer--portal on-dark" data-testid="portal-footer">
      <div className="wrap footer-portal">
        <span>{s.brand_name}</span>
        {s.phone && <a href={`tel:${s.phone}`}>{s.phone_display}</a>}
        {s.public_email && <a href={`mailto:${s.public_email}`}>{s.public_email}</a>}
        <Link prefetch={false} href="/">Website</Link>
        <Link prefetch={false} href="/contact">Contact</Link>
        <Link prefetch={false} href="/terms">Terms of use</Link>
        <Link prefetch={false} href="/privacy">Privacy policy</Link>
        <CookiePrefsButton />
      </div>
    </footer>
  );
  return <PortalSwitchFooter compact={compact} full={(
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
            {uses.map((l) => <li key={l.slug}><Link prefetch={false} href={l.path}>{l.name}</Link></li>)}
            <li><Link prefetch={false} href="/guides">Guides</Link></li>
          </ul></nav>
          {places.length > 0 && <nav aria-label="Locations"><h2>Locations</h2><ul>
            {places.map((l) => <li key={l.slug}><Link prefetch={false} href={l.path}>{l.name}</Link></li>)}
            <li><Link prefetch={false} href="/car-rental">All areas</Link></li>
          </ul></nav>}
          <div className="footer-contact"><h2>Talk to us</h2><ul>
            {s.phone && <li><a href={`tel:${s.phone}`}>{s.phone_display}</a><span>Phone and 24-hour roadside line</span></li>}
            {s.whatsapp && <li><a href={waLink(s.whatsapp)} rel="noopener">WhatsApp</a></li>}
            {s.public_email && <li><a href={`mailto:${s.public_email}`}>{s.public_email}</a></li>}
            <li><span>{[s.opening_hours_text, reply].filter(Boolean).join('. ')}.</span></li>
            {napAddress(s).street && <li><span data-testid="footer-address">{napAddress(s).line}</span></li>}
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
        {/* Browse (owner, October 22, 2026): the one quiet way into the place and service pages; they link on among themselves */}
        <nav aria-label="Browse" className="footer-browse"><h2>Browse</h2><ul>
          <li><Link prefetch={false} href="/car-rental/toronto">Car rental in {s.city}</Link></li>
          <li><Link prefetch={false} href="/car-rental/gta">Car rental across the GTA</Link></li>
          <li><Link prefetch={false} href="/car-rental">All rental areas and terms</Link></li>
          <li><Link prefetch={false} href="/detailing">Car detailing</Link></li>
          <li><Link prefetch={false} href="/body-shop">Auto body shop</Link></li>
          <li><Link prefetch={false} href="/buy/cars-for-sale/toronto">Buying a car</Link></li>
          <li><Link prefetch={false} href="/places">Every place we cover</Link></li>
          <li><Link prefetch={false} href="/makes">Every make and model</Link></li>
        </ul></nav>
        {/* 0124: the popular hubs of the priority list (cities nearest us, the first services, the popular makes and
            models), on every page, so a crawler reaches them in one click from anywhere */}
        {([['Cities', hubs?.places], ['Services', hubs?.services], ['Popular makes', hubs?.makes], ['Popular models', hubs?.models]] as const)
          .filter(([, l]) => l && l.length > 0).map(([h, l]) => (
            <nav key={h} aria-label={h} className="footer-browse"><h2>{h}</h2><ul>
              {l!.map((x) => <li key={x.path}><Link prefetch={false} href={x.path}>{x.name}</Link></li>)}
            </ul></nav>
          ))}
        <div className="footer-legal">
          <span>{s.brand_name}. {s.service_area}, Canada.</span>
          <span>Prices in Canadian dollars, before HST unless stated.</span>
          <Link prefetch={false} className="footer-investor" href="/investors">Investor sign in</Link>
        </div>
        <Wordmark s={s} className="wordmark--xl footer-mark" link={false} />
      </div>
    </footer>
  )} />;
}
