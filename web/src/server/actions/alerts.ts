'use server';
import { auth } from '@/lib/auth';
import { DbError, rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import type { ActionResult } from '@/features/forms/schemas';
import type { AlertPrefs } from '@/features/alerts/types';
import { TOPICS, type PushState, type Topic } from '@/features/push/topics';

// The staff Alerts feed and settings (migration 0466): mark read, snooze, quiet hours and focus mode, and a device's own
// topics. Each acts only on the signed-in person's own alerts (the database checks the person).
const SR = { role: 'service_role' as const };
const refused = (e: unknown) => ({ ok: false as const, code: 'refused', message: e instanceof DbError ? e.message : 'Not saved. Try again.' });

async function me() {
  return (await auth()).currentUser();
}

export async function markAlertsRead(ids: string[] | null): Promise<ActionResult<number>> {
  const u = await me();
  if (!u) return { ok: false, code: 'auth', message: 'Sign in first.' };
  const clean = Array.isArray(ids) ? ids.filter((x) => typeof x === 'string' && /^[0-9a-f-]{36}$/i.test(x)).slice(0, 200) : null;
  try {
    return { ok: true, data: Number(await rpc('server_alert_read', { p_user: u.id, p_ids: clean ?? undefined }, SR)) || 0 };
  } catch (e) { return refused(e); }
}

export async function snoozeAlert(id: string, minutes = 30): Promise<ActionResult<string | null>> {
  const u = await me();
  if (!u) return { ok: false, code: 'auth', message: 'Sign in first.' };
  if (typeof id !== 'string' || !/^[0-9a-f-]{36}$/i.test(id)) return { ok: false, code: 'invalid', message: 'No such alert.' };
  try {
    return { ok: true, data: ((await rpc('server_alert_snooze', { p_user: u.id, p_id: id, p_minutes: minutes }, SR)) as unknown as string | null) ?? null };
  } catch (e) { return refused(e); }
}

export async function saveAlertPrefs(p: { quiet_on?: boolean; quiet_from?: number; quiet_until?: number; focus_minutes?: number }): Promise<ActionResult<AlertPrefs>> {
  const u = await me();
  if (!u) return { ok: false, code: 'auth', message: 'Sign in first.' };
  const minute = (v: unknown) => (typeof v === 'number' && Number.isInteger(v) && v >= 0 && v < 1440 ? v : undefined);
  const clean: Record<string, unknown> = {};
  if (typeof p?.quiet_on === 'boolean') clean.quiet_on = p.quiet_on;
  if (minute(p?.quiet_from) !== undefined) clean.quiet_from = p.quiet_from;
  if (minute(p?.quiet_until) !== undefined) clean.quiet_until = p.quiet_until;
  if (typeof p?.focus_minutes === 'number' && p.focus_minutes >= 0 && p.focus_minutes <= 1440) clean.focus_minutes = Math.round(p.focus_minutes);
  try {
    return { ok: true, data: (await rpc('server_set_alert_prefs', { p_user: u.id, p: clean as Json }, SR)) as unknown as AlertPrefs };
  } catch (e) { return refused(e); }
}

/** This device's own topics; null follows the person's choice. */
export async function saveDeviceTopics(endpoint: string, topics: Topic[] | null): Promise<ActionResult<PushState>> {
  const u = await me();
  if (!u) return { ok: false, code: 'auth', message: 'Sign in first.' };
  if (typeof endpoint !== 'string' || !endpoint) return { ok: false, code: 'invalid', message: 'Turn alerts on for this device first.' };
  const clean = topics === null ? null : (Array.isArray(topics) ? topics : []).filter((t): t is Topic => (TOPICS as readonly string[]).includes(t));
  try {
    return { ok: true, data: (await rpc('server_push_device_topics', { p_user: u.id, p_endpoint: endpoint, p_topics: clean as unknown as string[] }, SR)) as unknown as PushState };
  } catch (e) { return refused(e); }
}

/** Alerts > Settings for the Admins: one rule on or off, or its tier. */
export async function saveAlertRule(rule: string, change: { enabled?: boolean; tier?: 'urgent' | 'normal' | 'digest' }): Promise<ActionResult<{ rule: string; enabled: boolean; tier: string }>> {
  const u = await me();
  if (!u) return { ok: false, code: 'auth', message: 'Sign in first.' };
  if (typeof rule !== 'string' || !/^[a-z][a-z0-9_:]*$/.test(rule)) return { ok: false, code: 'invalid', message: 'No such alert.' };
  const p: Record<string, unknown> = {};
  if (typeof change?.enabled === 'boolean') p.enabled = change.enabled;
  if (change?.tier === 'urgent' || change?.tier === 'normal' || change?.tier === 'digest') p.tier = change.tier;
  try {
    return { ok: true, data: (await rpc('server_set_alert_rule', { p_user: u.id, p_rule: rule, p: p as Json }, SR)) as unknown as { rule: string; enabled: boolean; tier: string } };
  } catch (e) { return refused(e); }
}
