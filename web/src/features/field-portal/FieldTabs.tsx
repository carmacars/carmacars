'use client';
import { usePathname } from 'next/navigation';
import Link from '@/components/Link';
import { FdIcon } from '@/features/field/icons';
import { activeTab, fieldTabs } from './model';

// The field portal's tabs (r35 part X): at most four, at the thumb, plus Sales for a person who opted in to sales.
export function FieldTabs({ salesOptIn, todo = 0 }: { salesOptIn: boolean; todo?: number }) {
  const path = usePathname() ?? '/staff/field';
  const on = activeTab(path);
  return (
    <nav className="fp-tabs" aria-label="Field work" data-testid="field-tabs">
      <ul className="fp-tabs__list">{fieldTabs({ salesOptIn }).map((t) => (
        <li key={t.href}><Link prefetch={false} href={t.href} aria-current={on === t.icon ? 'page' : undefined} data-testid={`tab-${t.icon}`}>
          <FdIcon name={t.icon} />{t.label}{t.icon === 'today' && todo > 0 ? <span className="fp-tabs__dot" aria-label={`${todo} to do`}>{todo}</span> : null}</Link></li>))}</ul>
    </nav>
  );
}
