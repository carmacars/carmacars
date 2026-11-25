// r50 (4600): a staff member's birthday, month and day only. Pure: the profile, the staff list and the tests share it.
export const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'] as const;

/** "March 14", or null when not set or not a real day of that month (February 29 is allowed). */
export function birthdayWords(month: number | null | undefined, day: number | null | undefined): string | null {
  if (!month || !day || month < 1 || month > 12) return null;
  const last = new Date(Date.UTC(2000, month, 0)).getUTCDate();
  return day >= 1 && day <= last ? `${MONTHS[month - 1]} ${day}` : null;
}

/** The staff list's "MM-DD" in words. */
export function birthdayOfKey(key: string | null | undefined): string | null {
  const m = /^(\d{2})-(\d{2})$/.exec(key ?? '');
  return m ? birthdayWords(Number(m[1]), Number(m[2])) : null;
}
