import Link from 'next/link';
import type { SiteSettings } from '@/lib/types';
import { Wordmark } from './Wordmark';
import { MenuButton, NavLink } from './HeaderClient';

export const NAV: [string, string, string][] = [
  ['/cars', 'Fleet', 'Every car, with dates and prices'], ['/how-it-works', 'How it works', 'Request to book'],
  ['/delivery', 'Delivery', 'Anywhere, airports too'], ['/requirements', 'Requirements', 'Age, licence, coverage'],
  ['/list-your-car', 'List your car', 'Owner program'], ['/faq', 'FAQ', 'Straight answers']
];

export function Header({ s }: { s: SiteSettings }) {
  return (
    <>
      <a className="skip" href="#main">Skip to content</a>
      <header className="site-header on-dark">
        <div className="wrap">
          <Wordmark s={s} />
          <nav className="nav" aria-label="Main">
            {NAV.map(([h, l]) => <NavLink key={h} className="nav__link" href={h}>{l}</NavLink>)}
          </nav>
          <div className="header-actions">
            <NavLink className="btn btn--quiet btn--sm header-signin" href="/sign-in">Sign in</NavLink>
            <Link prefetch={false} className="btn btn--primary btn--sm" href="/cars">Find a car</Link>
            <MenuButton />
          </div>
        </div>
      </header>
      <div className="menu-panel on-dark" id="menu" inert>
        <nav className="menu-panel__links" aria-label="Menu">
          {NAV.map(([h, l, sub]) => <NavLink key={h} href={h}>{l}<span>{sub}</span></NavLink>)}
          <NavLink href="/contact">Contact<span>Talk to a person</span></NavLink>
        </nav>
        <div className="row"><Link prefetch={false} className="btn btn--light" href="/sign-in">Sign in</Link><Link prefetch={false} className="btn btn--primary" href="/cars">Find a car</Link></div>
      </div>
    </>
  );
}
