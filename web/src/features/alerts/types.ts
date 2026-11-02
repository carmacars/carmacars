// The staff Alerts feed and settings (migration 0466).
export type AlertTier = 'urgent' | 'normal' | 'digest';
export type AlertFilter = 'all' | 'unread' | 'urgent';
export const FILTERS: ReadonlyArray<[AlertFilter, string]> = [['all', 'All'], ['unread', 'Unread'], ['urgent', 'Urgent']];

export interface AlertItem {
  id: string;
  code: string;
  tier: AlertTier;
  title: string;
  body: string | null;
  url: string;
  created_at: string;
  read_at: string | null;
  snoozed_until: string | null;
  group: string;
}

export interface AlertPrefs {
  custom: boolean;
  quiet_on: boolean;
  quiet_from: number;
  quiet_until: number;
  focus_until: string | null;
}

export interface AlertRule { rule: string; label: string; grp: string; who: string[]; tier: AlertTier; topic: string; enabled: boolean; fixed: boolean; hint: string | null }

export const TIER_LABEL: Record<AlertTier, string> = { urgent: 'Urgent', normal: 'Alert', digest: 'For the digest' };

/** A filter from the address (?f=), all when missing or unknown. */
export function filterOf(v: unknown): AlertFilter {
  return v === 'unread' || v === 'urgent' ? v : 'all';
}

/** Minutes of the day as 21:00. */
export function clock(min: number): string {
  const m = ((Math.round(min) % 1440) + 1440) % 1440;
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
}

/** The half hours of a day, for the quiet hours pickers. */
export const HALF_HOURS: number[] = Array.from({ length: 48 }, (_, i) => i * 30);

/** "5 min ago", "3 h ago", "Nov 2" (Toronto), from an ISO time. */
export function ago(iso: string, now = Date.now()): string {
  const s = Math.max(0, Math.round((now - new Date(iso).getTime()) / 1000));
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86_400) return `${Math.floor(s / 3600)} h ago`;
  return new Date(iso).toLocaleDateString('en-CA', { month: 'short', day: 'numeric', timeZone: 'America/Toronto' });
}

/** A phone number from the alert's Call button (/alerts/call?to=): digits and a leading plus only. */
export function callNumber(v: unknown): string | null {
  const s = typeof v === 'string' ? v.trim() : '';
  return /^\+?[0-9]{7,15}$/.test(s) ? s : null;
}
