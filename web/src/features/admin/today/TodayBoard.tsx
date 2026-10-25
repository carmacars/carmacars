import Link from 'next/link';
import type { ReactNode } from 'react';
import { PuIcon } from '@/components/portal-ui/icons';
import { LiveWait } from '../shell/LiveWait';
import type { BoardTile } from './board';

export { boardTiles, type BoardTile, type Dash } from './board';

// Admin > To do, the top (admin portal design, October 25, 2026; the owner: "extremely easy to use"): a dark band with
// the day, how much needs you, and a board of counts: requests waiting (with the oldest one's live timer), today's
// pickups and returns, payments to chase, deposits to settle, staff tasks and alerts. Each count is one link to where
// the work is done; a count that needs someone now is red and says so in words. The figures come from the same reads
// as Overview (dashboard) and To do (admin_todo); nothing is worked out here.

const greeting = (name: string | null) => {
  const h = Number(new Intl.DateTimeFormat('en-CA', { hour: 'numeric', hourCycle: 'h23', timeZone: 'America/Toronto' }).format(new Date()));
  const part = h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
  return name ? `${part}, ${name.split(' ')[0]}` : part;
};
const dayWords = () => new Intl.DateTimeFormat('en-CA', { weekday: 'long', month: 'long', day: 'numeric', timeZone: 'America/Toronto' }).format(new Date());

export function TodayBoard({ name, lead, tiles, actions }: { name: string | null; lead: ReactNode; tiles: BoardTile[]; actions?: ReactNode }) {
  return (
    <section className="ad-today" aria-labelledby="today-h" data-testid="today-board">
      <div className="ad-today__head">
        <div className="ad-today__text">
          <p className="ad-today__day">{dayWords()} <span aria-hidden="true">/</span> {greeting(name)}</p>
          <h1 className="ad-today__title" id="today-h">To do</h1>
          <p className="ad-today__lead" data-testid="today-lead">{lead}</p>
        </div>
        {actions && <div className="ad-today__actions">{actions}</div>}
      </div>
      <ul className="ad-board" aria-label="Today in numbers">
        {tiles.map((t) => (
          <li key={t.key}>
            <Link prefetch={false} href={t.href} className={`ad-board__tile${t.urgent ? ' is-urgent' : ''}${t.count === 0 ? ' is-zero' : ''}`} data-testid={`today-tile-${t.key}`}>
              <span className="ad-board__top"><span className="ad-board__icon"><PuIcon name={t.icon} /></span><span className="ad-board__label">{t.label}</span></span>
              <b className="ad-board__count">{t.count}</b>
              <span className="ad-board__note">{t.urgent ? <span className="vh">Needs you: </span> : null}{t.wait ? <LiveWait minutes={t.wait.minutes} target={t.wait.target} prefix="Oldest " /> : t.note}</span>
            </Link>
          </li>
        ))}
      </ul>
    </section>
  );
}
