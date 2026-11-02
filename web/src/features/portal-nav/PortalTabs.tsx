import Link from 'next/link';
import type { PageTab } from './tabs';

// The tab row of a merged portal page (r27 portals): the subject's name with a red mark, then its tabs, the current one
// black. The admin tab row's look (HubBar on r27-nav). On a phone the name sits above and the tabs share the row.
export function PortalTabs({ label, tabs, current, counts = {}, testId = 'portal-tabs' }: { label: string; tabs: PageTab[]; current: string; counts?: Record<string, number>; testId?: string }) {
  if (tabs.length < 2) return null;
  return (
    <nav className="ptabs" aria-label={label} data-testid={testId}>
      <span className="ptabs__name" aria-hidden="true">{label}</span>
      <div className="ptabs__row" style={{ ['--ptabs-n' as string]: tabs.length }}>
        {tabs.map((t) => (
          <Link prefetch={false} scroll={false} key={t.key} href={t.href} aria-current={t.key === current ? 'page' : undefined} data-testid={`tab-${t.key}`}>
            {t.label}{counts[t.key] ? <span className="pt__count" aria-label={`${counts[t.key]} new`}>{counts[t.key]}</span> : null}
          </Link>
        ))}
      </div>
    </nav>
  );
}
