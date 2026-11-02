import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { AlertItem, AlertPrefs, AlertFilter, AlertRule } from '@/features/alerts/types';

// The staff Alerts feed (migration 0466): every staff notice of the signed-in person (the urgent, normal and digest staff
// alerts of the rule table and the older staff notices), newest first, read through the server only.
const SR = { role: 'service_role' as const };

export async function alertFeed(userId: string, filter: AlertFilter = 'all', limit = 80): Promise<AlertItem[]> {
  try {
    return ((await rpc('server_alert_feed', { p_user: userId, p_limit: limit, p_filter: filter }, SR)) as unknown as AlertItem[]) ?? [];
  } catch {
    return [];
  }
}

export async function alertUnread(userId: string): Promise<number> {
  try {
    return Number(await rpc('server_alert_unread', { p_user: userId }, SR)) || 0;
  } catch {
    return 0;
  }
}

export async function alertPrefs(userId: string): Promise<AlertPrefs | null> {
  try {
    return (await rpc('server_alert_prefs', { p_user: userId }, SR)) as unknown as AlertPrefs;
  } catch {
    return null;
  }
}


/** The rule table (Admins only). */
export async function alertRules(userId: string): Promise<AlertRule[]> {
  try {
    return ((await rpc('server_alert_rules', { p_user: userId }, SR)) as unknown as AlertRule[]) ?? [];
  } catch {
    return [];
  }
}
