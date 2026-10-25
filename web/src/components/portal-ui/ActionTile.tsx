import Link from 'next/link';
import type { ReactNode } from 'react';
import { PuIcon, type IconName } from './icons';

export interface ActionTileItem { key: string; title: ReactNode; note?: ReactNode; href: string; cta: string; icon?: IconName; urgent?: boolean; testId?: string }

/** One thing that needs the person, as a tile: an icon, what it is, and the one action (the whole tile is the link). */
export function ActionTile({ item }: { item: ActionTileItem }) {
  return (
    <li data-testid={item.testId}>
      <Link prefetch={false} href={item.href} className={`pu-action${item.urgent ? ' pu-action--urgent' : ''}`}>
        <span className="pu-action__icon"><PuIcon name={item.icon ?? 'arrow'} /></span>
        <span className="pu-action__text"><span className="pu-action__title">{item.title}</span>{item.note && <span className="pu-action__note">{item.note}</span>}</span>
        <span className="pu-action__cta">{item.cta}<PuIcon name="arrow" /></span>
      </Link>
    </li>
  );
}

/** "Needs your attention" as tiles. Nothing to show: nothing rendered. */
export function ActionTiles({ items, title = 'Needs your attention', testId = 'attention' }: { items: ActionTileItem[]; title?: string; testId?: string }) {
  if (!items.length) return null;
  return (
    <section className="stack" aria-labelledby={`${testId}-h`} data-testid={testId}>
      <h2 className="pt-section-title" id={`${testId}-h`}>{title}</h2>
      <ul className="pu-actions">{items.map((i) => <ActionTile key={i.key} item={i} />)}</ul>
    </section>
  );
}
