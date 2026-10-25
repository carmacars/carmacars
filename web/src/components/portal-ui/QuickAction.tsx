import Link from 'next/link';
import type { ReactNode } from 'react';
import { PortalIcon, type PortalIconName } from './icons';

type Tone = 'neutral' | 'brand' | 'dark' | 'warn';
const cx = (...c: Array<string | false | null | undefined>) => c.filter(Boolean).join(' ');

/** One quick action (a grid of them, unlike ActionTile which is one pending thing with its button): an icon, what it does and a line under it. A link (page, phone, anchor) or, with `as`, any element. */
export function QuickAction({ href, icon, title, note, tone = 'neutral', testId, children }: { href?: string; icon: PortalIconName; title: ReactNode; note?: ReactNode; tone?: Tone; testId?: string; children?: ReactNode }) {
  const inner = (
    <>
      <span className="pu-tile__icon"><PortalIcon name={icon} size={20} /></span>
      <span className="pu-tile__text"><span className="pu-tile__title">{title}</span>{note && <span className="pu-tile__note">{note}</span>}</span>
      <span className="pu-tile__go" aria-hidden="true"><PortalIcon name="arrow" size={16} /></span>
    </>
  );
  const cls = cx('pu-tile', `pu-tone-${tone}`);
  if (children) return <div className={cls} data-testid={testId}>{inner}<span className="pu-tile__slot">{children}</span></div>;
  if (!href) return null;
  if (/^(tel:|mailto:|https?:)/.test(href)) return <a className={cls} href={href} data-testid={testId}>{inner}</a>;
  return <Link prefetch={false} className={cls} href={href} data-testid={testId}>{inner}</Link>;
}
export function QuickActions({ children, label }: { children: ReactNode; label?: string }) {
  return <div className="pu-tiles" role={label ? 'group' : undefined} aria-label={label}>{children}</div>;
}

