'use client';
import Link from '@/components/Link';
import { usePathname, useSearchParams } from 'next/navigation';
import { Suspense } from 'react';
import { placeOf, type Hub, type Section } from './hubs';

// The rows on top of a page (r27): the section's pages (Cars: Vehicles, Listings, Maintenance), then, when the page is in a
// page group, the group's tabs (Vehicles: All cars, Rates for many cars...). Red, black and white; on a phone each row
// scrolls sideways with the current one in view. Nothing shows on a page outside them or on a detail page.
const seen = (el: HTMLAnchorElement | null) => { el?.scrollIntoView?.({ block: 'nearest', inline: 'nearest' }); };

function Bar({ hubs, sections, counts }: { hubs: Hub[]; sections: Section[]; counts: Record<string, number> }) {
  const path = usePathname() ?? '';
  const sp = useSearchParams();
  const { section, hub } = placeOf(sections, hubs, path, sp?.toString() ?? '');
  const tabs = hub && hub.hub.tabs.length > 1 && (!section || section.current.key === hub.hub.key) ? hub : null;
  if (!section && !tabs) return null;

  return (
    <div className="hub-rows" data-testid="hub-rows">
      {section && (
        <nav className="hub hub--section" aria-label={section.label} data-testid="section-bar">
          <span className="hub__name" aria-hidden="true">{section.label}</span>
          <div className="hub__tabs">
            {section.items.map((i) => (
              <Link prefetch={false} scroll={false} key={i.key} href={i.href} aria-current={i === section.current ? (tabs ? 'true' : 'page') : undefined} ref={i === section.current ? seen : undefined}>
                {i.label}{counts[i.href] ? <span className="pt__count">{counts[i.href]}</span> : null}
              </Link>
            ))}
          </div>
        </nav>
      )}
      {tabs && (
        <nav className={`hub${section ? ' hub--sub' : ''}`} aria-label={tabs.hub.label} data-testid="hub-bar" data-hub={tabs.hub.key}>
          {!section && <span className="hub__name" aria-hidden="true">{tabs.hub.label}</span>}
          <div className="hub__tabs">
            {tabs.hub.tabs.map((t) => (
              <Link prefetch={false} scroll={false} key={t.href} href={t.href} aria-current={t === tabs.tab ? 'page' : undefined} ref={t === tabs.tab ? seen : undefined}>
                {t.label}{counts[t.href] ? <span className="pt__count">{counts[t.href]}</span> : null}
              </Link>
            ))}
          </div>
        </nav>
      )}
    </div>
  );
}

export function HubBar({ hubs, sections = [], counts = {} }: { hubs: Hub[]; sections?: Section[]; counts?: Record<string, number> }) {
  return <Suspense fallback={null}><Bar hubs={hubs} sections={sections} counts={counts} /></Suspense>;
}
