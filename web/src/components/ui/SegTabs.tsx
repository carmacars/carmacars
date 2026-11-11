import Link from '@/components/Link';

// The style guide's tabs (r35 UX; docs/style-guide.md): the Visitors segmented control. A grey track, the current tab a black
// pill with a red underline, a count as a red badge. Links, so each tab has its own address. Styles: styles/ui-kit.css.
export interface SegTab { href: string; label: string; count?: number; testId?: string }
export function SegTabs({ items, current, label, testId }: { items: SegTab[]; current: string; label: string; testId?: string }) {
  return (
    <nav className="ui-tabs" aria-label={label} data-testid={testId}>
      {items.map((t) => (
        <Link prefetch={false} scroll={false} key={t.href} href={t.href} aria-current={t.href === current ? 'page' : undefined} data-testid={t.testId}>
          {t.label}{t.count ? <span className="pt__count" aria-label={`${t.count} waiting`}>{t.count}</span> : null}
        </Link>))}
    </nav>
  );
}
