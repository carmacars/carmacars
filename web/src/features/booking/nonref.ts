// The non-refundable discount's week-ahead rule (migration 0241). No imports: Worker and `node --test`.
/** Whether the non-refundable discount may be chosen: the pickup is at least `minDays` days after today (0241). */
export function nonRefAllowed(fromIso: string, todayIso: string, minDays: number | undefined): boolean {
  if (!minDays || !fromIso) return true;
  const d = (Date.parse(`${fromIso}T00:00:00Z`) - Date.parse(`${todayIso}T00:00:00Z`)) / 86_400_000;
  return Number.isFinite(d) && d >= minDays;
}
