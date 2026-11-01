'use client';
import Link from 'next/link';
import { usePathname, useSearchParams } from 'next/navigation';
import { Suspense } from 'react';
import { hubOf, type Hub } from './hubs';

// The tab row of a page group (r27): the group's name and its pages, on top of each of them. One row; on a phone it
// scrolls sideways with the current tab in view. Nothing shows on a page outside a group or on a detail page.
function Bar({ hubs, counts }: { hubs: Hub[]; counts: Record<string, number> }) {
  const path = usePathname() ?? '';
  const sp = useSearchParams();
  const at = hubOf(hubs, path, sp?.toString() ?? '');
  if (!at) return null;
  return (
    <nav className="hub" aria-label={at.hub.label} data-testid="hub-bar" data-hub={at.hub.key}>
      <span className="hub__name" aria-hidden="true">{at.hub.label}</span>
      <div className="hub__tabs">
        {at.hub.tabs.map((t) => (
          <Link prefetch={false} scroll={false} key={t.href} href={t.href} aria-current={t === at.tab ? 'page' : undefined}
            ref={t === at.tab ? (el) => { el?.scrollIntoView?.({ block: 'nearest', inline: 'nearest' }); } : undefined}>
            {t.label}{counts[t.href] ? <span className="pt__count">{counts[t.href]}</span> : null}
          </Link>
        ))}
      </div>
    </nav>
  );
}

export function HubBar({ hubs, counts = {} }: { hubs: Hub[]; counts?: Record<string, number> }) {
  return <Suspense fallback={null}><Bar hubs={hubs} counts={counts} /></Suspense>;
}
