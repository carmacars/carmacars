import type { IconName } from '@/components/portal-ui/icons';

// The counts on the board at the top of Admin > To do (TodayBoard.tsx), from the dashboard read (the same as Overview)
// and admin_todo. Nothing is worked out beyond counting what the two reads return.

export interface Dash {
  target_minutes: number;
  requests: Array<{ booking_number: string; waiting_minutes: number; awaiting_renter: boolean }>;
  offers: unknown[];
  payments_failed: unknown[];
  deposits_due: Array<{ kind: string }>;
  late: unknown[];
  tasks: Array<{ queue: string; open: number; overdue: number; escalated: number }>;
  alerts: unknown[];
}

/** One count: its words, where it is worked, and either a short note or the oldest wait (shown as a live timer). */
export interface BoardTile { key: string; label: string; count: number; href: string; icon: IconName; note: string; urgent?: boolean; wait?: { minutes: number; target: number } }

export function boardTiles(dash: Dash | null, today: { pickups: Array<{ ready: boolean }>; returns: Array<{ late: boolean }>; late: number }, siteProblems: number): BoardTile[] {
  const waiting = dash ? dash.requests.filter((r) => !r.awaiting_renter) : [];
  const oldest = waiting.reduce((m, r) => Math.max(m, r.waiting_minutes), 0);
  const target = dash?.target_minutes ?? 5;
  const notReady = today.pickups.filter((p) => !p.ready).length;
  const tasks = dash ? dash.tasks.reduce((n, q) => n + q.open, 0) : 0;
  const overdue = dash ? dash.tasks.reduce((n, q) => n + q.overdue, 0) : 0;
  const deposits = dash?.deposits_due.length ?? 0;
  const take = dash ? dash.deposits_due.filter((x) => x.kind === 'take').length : 0;
  const failed = dash?.payments_failed.length ?? 0;
  const alerts = (dash?.alerts.length ?? 0) + siteProblems;
  const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
  return [
    { key: 'requests', label: 'Requests waiting', count: waiting.length, href: '/admin/requests', icon: 'clock', urgent: waiting.length > 0 && oldest > target,
      note: `Reply target ${target} min`, wait: waiting.length ? { minutes: oldest, target } : undefined },
    { key: 'pickups', label: 'Pickups today', count: today.pickups.length, href: '/admin/calendar', icon: 'car', urgent: notReady > 0,
      note: today.pickups.length ? (notReady ? `${notReady} not ready` : 'All ready') : 'None today' },
    { key: 'returns', label: 'Returns today', count: today.returns.length, href: today.late ? '/admin/bookings?status=on_rent' : '/admin/calendar', icon: 'check', urgent: today.late > 0,
      note: today.late ? `${today.late} late now` : today.returns.length ? 'None late' : 'None today' },
    { key: 'payments', label: 'Payments to chase', count: failed, href: '/admin/money?status=failed', icon: 'pay', urgent: failed > 0, note: failed ? 'Declined or failed' : 'Nothing failed' },
    { key: 'deposits', label: 'Deposits to settle', count: deposits, href: '/admin/money?tab=deposits', icon: 'bank',
      note: deposits ? `${take} to take, ${deposits - take} to release` : 'Nothing due' },
    { key: 'tasks', label: 'Staff tasks open', count: tasks, href: '/admin/tasks', icon: 'doc', urgent: overdue > 0, note: overdue ? `${overdue} overdue` : tasks ? 'None overdue' : 'All done' },
    { key: 'alerts', label: 'Alerts', count: alerts, href: siteProblems ? '#site-health' : '/admin/overview', icon: 'alert', urgent: alerts > 0,
      note: alerts ? `${plural(alerts, 'thing', 'things')} to fix` : 'All working' }
  ];
}
