'use server';
import { after } from 'next/server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { runListingWorkerNow } from '@/server/listing-worker';

// The listing pipeline's screens (migration 0032, through the door's ops calls): start a listing, see the
// capture and the progress, submit, retry a step. Who may do what is the database's (app.user_may_list):
// an owner for their own car, field staff for a car of their job, Fleet and Admins for any car, customer
// service to review. After a submit or a retry the worker runs once right away, after the response.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}

function kick() {
  after(async () => { try { await runListingWorkerNow({ maxJobs: 40, deadlineMs: 25_000 }); } catch { /* the cron sweep picks it up */ } });
}

export async function listingStart(p: { vehicle_id?: string; vin?: string; plate?: string; colour?: string; odometer_km?: number; notes?: string }): Promise<R<{ intake_id: string; state: string; existing: boolean }>> {
  try {
    const { user, aal } = await me();
    const data = await door<{ intake_id: string; state: string; existing: boolean }>(user.id, 'ops_do', 'listing_start', p, aal);
    kick();
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function listingSubmit(intake: string, refresh: string[] = []): Promise<R<{ state: string }>> {
  try {
    const { user, aal } = await me();
    const data = await door<{ state: string }>(user.id, 'ops_do', 'listing_submit', { intake }, aal);
    kick();
    for (const x of refresh) revalidatePath(x);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function listingRetryJob(job: string, refresh: string[] = []): Promise<R<{ status: string; state: string }>> {
  try {
    const { user, aal } = await me();
    const data = await door<{ status: string; state: string }>(user.id, 'ops_do', 'listing_job_retry', { job }, aal);
    kick();
    for (const x of refresh) revalidatePath(x);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function listingProgress<T = Record<string, unknown>>(intakes: string[]): Promise<R<Record<string, T>>> {
  try {
    const { user, aal } = await me();
    return { ok: true, data: await door<Record<string, T>>(user.id, 'ops_read', 'listing_progress', { intakes: intakes.slice(0, 200) }, aal) };
  } catch (e) { return fail(e); }
}

export async function listingCapture<T = Record<string, unknown>>(intake: string): Promise<R<T>> {
  try {
    const { user, aal } = await me();
    return { ok: true, data: await door<T>(user.id, 'ops_read', 'listing_capture', { intake }, aal) };
  } catch (e) { return fail(e); }
}
