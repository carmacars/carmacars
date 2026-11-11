// r35 UX (1107): the Prepare checklist of a rental in plain words (the office's read-only view). Pure; prepare.test.ts.
import type { Addon } from './model.ts';

export interface PrepareProgressData {
  booking_id: string; booking_number: string; status: string; pickup_at: string;
  items: Addon[]; total: number; ticked: number;
  job: { id: string; kind: string; status: string; scheduled_at: string; started_at: string | null; completed_at: string | null; who: string | null } | null;
}

const JOB: Record<string, string> = { handover: 'Pickup', delivery: 'Delivery' };
const STATUS: Record<string, string> = { scheduled: 'scheduled', acknowledged: 'acknowledged', in_progress: 'under way', done: 'done', cancelled: 'cancelled' };

export function prepareWords(d: PrepareProgressData): { count: string; done: boolean; job: string } {
  const done = d.total === 0 || d.ticked >= d.total;
  const count = d.total === 0 ? 'Nothing to prepare' : `${d.ticked} of ${d.total} in the car`;
  const job = d.job
    ? `${JOB[d.job.kind] ?? 'Job'} ${STATUS[d.job.status] ?? d.job.status.replace(/_/g, ' ')}${d.job.who ? `, ${d.job.who}` : ', no field person yet'}.`
    : 'No pickup or delivery job yet.';
  return { count, done, job };
}
