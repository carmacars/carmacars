// Release 42: the minute tick on the company's server (scripts/vps-server.mjs), the same plan as the Worker's cron
// trigger (custom-worker.ts scheduled): which of the app's protected job routes a tick asks for. Pure and without
// imports that run (the type import is erased), so the Node server and the unit test share it.
// Keep in step with custom-worker.ts scheduled while both hosts exist; src/lib/platform/cron-plan.test.ts lists the jobs.
import type { JobsDue } from '../edge/cron-gate.ts';

export interface JobCall { path: string; body?: string }

/** The jobs of a five-minute tick (plan.full), in the Worker's order; none on the minutes between (those only ask the
 *  database which notices are due, src/lib/edge/notify-kick.ts kickNow). */
export function jobsForTick(plan: { full: boolean; minute: number }, due: JobsDue, pushDue: boolean): JobCall[] {
  if (!plan.full) return [];
  const jobs: JobCall[] = [];
  const add = (on: unknown, path: string, body?: string) => { if (on) jobs.push(body ? { path, body } : { path }); };
  add(due.listing, '/api/jobs/listing');
  add(due.seo, '/api/jobs/seo');
  add(due.phone, '/api/jobs/phone');
  add(due.interviews, '/api/jobs/interviews');
  add(pushDue, '/api/jobs/push');
  add(due.reviews, '/api/jobs/reviews');
  add(due.meet, '/api/jobs/meet');
  add(due.gsc, '/api/jobs/gsc');
  add(due.ads, '/api/jobs/ads');
  add(due.car_values, '/api/jobs/car-values');
  // a car put on or taken off the site in the database alone: the route rebuilds only when the fleet's signature changed
  add(true, '/api/jobs/public-rebuild', '{"check":true}');
  // the monthly statement emails, once an hour: the first tick of each hour
  add(plan.minute < 5, '/api/jobs/statements');
  add(due.pdf, '/api/jobs/pdf');
  add(due.turo, '/api/jobs/turo-rematch');
  add(due.agreements, '/api/jobs/agreements');
  add(due.crm, '/api/jobs/partner-crm');
  add(due.deposits, '/api/jobs/deposits');
  // the retention purge once an hour on the second tick, the usage guard on the third
  add(plan.minute >= 5 && plan.minute < 10, '/api/jobs/purge');
  add(plan.minute >= 10 && plan.minute < 15, '/api/jobs/usage');
  return jobs;
}

/** Whether this process runs the tick: only with CRON_ENABLED=1, so the server never runs the jobs a second time while
 *  the Worker's cron trigger still does (docs/hosting/off-cloudflare.md, the cutover order). */
export function cronEnabled(e: Record<string, string | undefined> = process.env): boolean {
  return ['1', 'true', 'yes', 'on'].includes((e.CRON_ENABLED ?? '').trim().toLowerCase());
}
