import Link from '@/components/Link';
import { Ico } from '@/features/seo/kit/icons';
import '@/styles/seo-kit.css';
import { promoCards, type ServiceKey } from './catalog';
import { getServiceFacts } from './data';

// The services module of every search page (release 48): the tracker, the owner program, the chauffeur and a car rental
// first (r50 hotfix 2), then delivery, coverage, the kinds of renters and the add-ons, as cards with an icon, one line, a price when the database
// has one, and a link. A snap carousel on a phone, a grid on a wide screen. Server-rendered; nothing shows if the read fails.
export async function ServicePromo({ exclude = null, pageKey = '', title = 'More from CarmaCars', n = 10, bare = false }: { exclude?: ServiceKey | readonly ServiceKey[] | null; pageKey?: string; title?: string; n?: number; /** inside a page's own column: no gutter of its own */ bare?: boolean }) {
  const f = await getServiceFacts().catch(() => null);
  if (!f) return null;
  const cards = promoCards(f, exclude, pageKey, n);
  if (!cards.length) return null;
  return (
    <section className="sk sk-promo" aria-labelledby="h-services" data-testid="service-promo">
      <div className={bare ? undefined : 'wrap'}>
        <div className="sk-sec__head">
          <p className="sk-sec__kicker">Services</p>
          <h2 className="d2" id="h-services">{title.replace('CarmaCars', f.brand)}</h2>
          <p>Renting a car is one of the things we do. <Link prefetch={false} className="link" href="/services">See every service</Link></p>
        </div>
        <ul className="sk-promo__track">
          {cards.map((c) => (
            <li key={c.key}>
              <Link prefetch={false} className={`sk-promo__card${c.feature ? ' sk-promo__card--feature' : ''}`} href={c.href} data-service={c.key}>
                <span className="sk-tile__ico"><Ico name={c.icon} /></span>
                <h3>{c.title}</h3>
                <p>{c.line}</p>
                <span>{c.fact && <span className="sk-promo__fact num">{c.fact}<br /></span>}<span className="sk-promo__go">{c.go} <Ico name="arrow" /></span></span>
              </Link>
            </li>))}
        </ul>
      </div>
    </section>
  );
}
