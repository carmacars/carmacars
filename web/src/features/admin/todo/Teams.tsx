import Link from '@/components/Link';
import { Card } from '@/features/admin/ui';
import { teamLine } from './need';
import type { TodoTeam } from './types';

// 0320: each staff team's work on one quiet line (its open tasks, its count lines underneath), never in "need you": the
// owner's To do is what needs the Admin. A team nobody real holds yet says so; its queue is one tap away.
export function Teams({ teams }: { teams: TodoTeam[] }) {
  return (
    <Card title="Your teams" testId="todo-teams" aside={<Link prefetch={false} className="link small" href="/admin/tasks">Staff tasks</Link>}>
      <ul className="ad-teams">{teams.map((tm) => (
        <li key={tm.key} className="ad-teams__row" data-testid={`todo-team-${tm.key}`} data-open={tm.open}>
          <span className="ad-teams__main">
            <Link prefetch={false} className="link ad-teams__name" href={tm.href}>{teamLine(tm)}</Link>
            {!tm.staffed && <span className="ad-sub">Nobody on this team yet: open the queue when you have a moment.</span>}
            {tm.items.length > 0 && <span className="ad-sub">{tm.items.map((i, n) => <span key={i.key} data-testid={`todo-${i.key}`}>{n ? ' · ' : ''}<Link prefetch={false} className="link" href={i.href}>{i.count} {i.label.charAt(0).toLowerCase() + i.label.slice(1)}</Link></span>)}</span>}
          </span>
          {tm.overdue > 0 && <span className="ad-pill ad-pill--red">{tm.overdue} overdue</span>}
        </li>))}
      </ul>
    </Card>
  );
}

