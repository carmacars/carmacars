// Everything CarmaCars does besides renting a car, as the search pages promote it (release 48,
// docs/changes/2026-11-20-r48-seo.md): the owner asked that every search page carry the other services as designed
// modules. Pure: titles and one-line descriptions are fixed; every price or number on a card comes from the database
// (ServiceFacts), and a card whose fact is unknown shows no number. Relative imports only (unit tested in Node).
import { money } from '../../lib/format.ts';
import type { KitIcon } from '../seo/kit/icons.tsx';

export interface ServiceFacts {
  brand: string; city: string;
  trackerPrice: string | null; trackerAvailable: boolean; trackerNote: string; trackerOn: boolean;
  deliveryFromCents: number | null; chauffeurFromCents: number | null; minAge: number | null; licence: string | null;
  airports: Array<{ code: string; name: string }>; coverageOptions: number;
  addons: Array<{ code: string; name: string; price_cents: number | null; pricing_unit: string }>;
  /** the landing pages that exist (their slugs), so a card never links to a page that is not there */
  landing: ReadonlySet<string>;
}
export type ServiceKey = 'trackers' | 'owner' | 'chauffeur' | 'delivery' | 'airport' | 'coverage' | 'detailing' | 'bodyshop' | 'monthly' | 'replacement' | 'rideshare' | 'young' | 'addons';
export interface ServiceCard { key: ServiceKey; icon: KitIcon; title: string; line: string; fact: string | null; href: string; go: string; feature?: boolean;
  /** the pages of this service's cluster (the hub page lists them) */ more: Array<{ href: string; label: string }> }

const unit = (u: string) => (u === 'per_day' ? ' a day' : u === 'per_hour' ? ' an hour' : '');
export const addonPrice = (a: { price_cents: number | null; pricing_unit: string }) => (a.price_cents ? `${money(a.price_cents)}${unit(a.pricing_unit)}` : null);
const land = (f: ServiceFacts, slug: string, label: string) => (f.landing.has(slug) ? [{ href: `/car-rental/${slug}`, label }] : []);

/** Every service card, in the order the pages show them. A service that is switched off is left out. */
export function serviceCards(f: ServiceFacts): ServiceCard[] {
  const addon = (code: string) => f.addons.find((a) => a.code === code);
  const seat = addon('child_seat') ?? addon('baby_seat');
  const cards: Array<ServiceCard | null> = [
    f.trackerOn ? { key: 'trackers', icon: 'pin', feature: true, title: 'GPS tracker and kill switch', line: 'See your car live, lock it and keep it from being started, from your phone.',
      fact: f.trackerPrice ? `${f.trackerPrice}${f.trackerAvailable ? '' : ` · ${f.trackerNote}`}` : f.trackerAvailable ? null : f.trackerNote, href: '/trackers', go: f.trackerAvailable ? 'See the tracker' : 'Pre-order or join the waitlist',
      more: [{ href: '/trackers/kill-switch-for-car', label: 'Kill switch for a car' }, { href: '/trackers/gps-tracker-for-rental-car', label: 'GPS tracker for rental cars' }, { href: '/trackers/anti-theft-tracker-toronto', label: `Anti-theft tracker in ${f.city}` },
        { href: '/trackers/fleet-tracking', label: 'Fleet tracking' }, { href: '/trackers/turo-host-gps-tracker', label: 'Tracker for Turo hosts' }, { href: '/trackers/install', label: 'Tracker install near you' }] } : null,
    { key: 'owner', icon: 'key', title: 'List your car and earn', line: 'We find the renters, check them, take the payments and send you a monthly statement.', fact: null, href: '/list-your-car', go: 'See the owner program',
      more: [{ href: '/list-your-car', label: 'The owner program' }, { href: '/list-your-car/apply', label: 'Apply with your car' }, ...(f.trackerOn ? [{ href: '/trackers/gps-tracker-for-rental-car', label: 'The tracker in every owner car' }] : [])] },
    { key: 'chauffeur', icon: 'wheel', title: 'Chauffeur service', line: 'A professional driver and car by the hour: airport runs, weddings, nights out.', fact: f.chauffeurFromCents ? `From ${money(f.chauffeurFromCents)} an hour` : null, href: '/chauffeur', go: 'Book a chauffeur',
      more: [{ href: '/chauffeur', label: 'Chauffeur service by the hour' }, { href: '/chauffeur/request', label: 'Request a chauffeur' }] },
    { key: 'delivery', icon: 'truck', title: 'Delivery and pickup', line: 'The car comes to your door, your hotel or the terminal, and we collect it after.', fact: f.deliveryFromCents ? `Delivered from ${money(f.deliveryFromCents)}` : null, href: '/delivery', go: 'How delivery works',
      more: [{ href: '/delivery', label: 'Delivery and pickup' }, ...land(f, 'car-delivery', 'Car rental delivery'), ...land(f, 'airport', 'Airport car rental'), ...f.airports.slice(0, 3).map((a) => ({ href: `/airport-car-rental/${a.code.toLowerCase()}`, label: `Delivered to ${a.name}` }))] },
    { key: 'coverage', icon: 'shield', title: 'Coverage options', line: `Liability is in every rate. ${f.coverageOptions || 'Three'} ways to cover the car itself, your card's among them.`, fact: null, href: '/requirements#coverage', go: 'Compare the options',
      more: [{ href: '/requirements#coverage', label: 'The coverage options compared' }, { href: '/credit-card-rental-coverage', label: 'Using your credit card\'s coverage' }, ...land(f, 'insurance-included', 'Car rental with insurance included')] },
    { key: 'monthly', icon: 'calendar', title: 'Monthly and long-term', line: 'One car for a month or more at the monthly rate, extended from your account.', fact: null, href: f.landing.has('monthly') ? '/car-rental/monthly' : '/cars', go: 'See monthly rentals',
      more: [...land(f, 'monthly', 'Monthly car rental'), ...land(f, 'weekly', 'Weekly car rental'), ...land(f, 'weekend', 'Weekend car rental')] },
    { key: 'replacement', icon: 'card', title: 'Insurance replacement', line: 'A car while yours is repaired. We can bill your insurer when the adjuster approves.', fact: null, href: f.landing.has('insurance-replacement') ? '/car-rental/insurance-replacement' : '/contact', go: 'Get a replacement car',
      more: [...land(f, 'insurance-replacement', 'Insurance replacement rental'), { href: '/body-shop', label: 'Body shop and collision repair' }] },
    { key: 'rideshare', icon: 'users', title: 'Rideshare and delivery drivers', line: 'Uber, Lyft and delivery apps are welcome under the rental agreement, with the documents the platforms ask for.', fact: null,
      href: f.landing.has('rideshare') ? '/car-rental/rideshare' : '/requirements', go: 'Rent for rideshare', more: [...land(f, 'rideshare', 'Car rental for rideshare drivers')] },
    { key: 'young', icon: 'star', title: `Drivers from ${f.minAge ?? 18}, G2 welcome`, line: `Every car takes drivers ${f.minAge ?? 18} and older${f.licence ? ` with an Ontario ${f.licence} licence` : ''}.`, fact: null,
      href: f.landing.has('young-drivers') ? '/car-rental/young-drivers' : '/requirements', go: 'See who can rent',
      more: [...land(f, 'young-drivers', 'Car rental at 18 to 20'), ...land(f, 'under-25', 'Car rental under 25'), ...land(f, 'g2-licence', 'Car rental with a G2 licence'), { href: '/requirements', label: 'Requirements' }] },
    { key: 'addons', icon: 'plug', title: 'Add-ons: charger, flowers, child seats', line: 'Ready in the car at pickup: a phone charger, a bouquet, a child or baby seat.',
      fact: [addon('phone_charger') && addonPrice(addon('phone_charger')!) ? `Charger ${addonPrice(addon('phone_charger')!)}` : null, seat && addonPrice(seat) ? `Seats ${addonPrice(seat)}` : null].filter(Boolean).join(' · ') || null,
      href: f.landing.has('with-a-charger') ? '/services#addons' : '/cars', go: 'See the add-ons',
      more: [...land(f, 'with-a-charger', 'Car rental with a phone charger'), ...land(f, 'with-flowers', 'Car rental with flowers'), ...land(f, 'with-child-seat', 'Car rental with a child seat')] },
    { key: 'detailing', icon: 'sparkle', title: 'Car detailing', line: 'Interior, exterior and full details, at your place or ours.', fact: null, href: '/detailing', go: 'See detailing', more: [{ href: '/detailing', label: 'Car detailing' }] },
    { key: 'bodyshop', icon: 'wrench', title: 'Body work and collision repair', line: 'Dents, scratches and collision repair, with a rental car while yours is in.', fact: null, href: '/body-shop', go: 'See body work', more: [{ href: '/body-shop', label: 'Auto body shop' }] }
  ];
  return cards.filter((c): c is ServiceCard => c !== null);
}

/** The cards of the module on a search page: never the page's own service, the tracker first, at most `n`; the choice
 *  turns with the page (its address), so across the site every service is linked from many pages. */
export function promoCards(f: ServiceFacts, exclude: ServiceKey | null, pageKey: string, n = 8): ServiceCard[] {
  const all = serviceCards(f).filter((c) => c.key !== exclude);
  const lead = all.filter((c) => c.feature || c.key === 'owner');
  const rest = all.filter((c) => !lead.includes(c));
  let h = 0; for (const ch of pageKey) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  const turned = rest.length ? [...rest.slice(h % rest.length), ...rest.slice(0, h % rest.length)] : rest;
  return [...lead, ...turned].slice(0, n);
}
