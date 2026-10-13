// The calendar's range: from midnight in Toronto on the start day, for the view's number of days.
const DAYS: Record<string, number> = { week: 7, two: 14, month: 31 };
export function rangeFrom(start: string | undefined, view: string | undefined) {
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const s = /^\d{4}-\d{2}-\d{2}$/.test(start ?? '') ? start! : today;
  // midnight in Toronto (the offset of that day)
  const probe = new Date(`${s}T12:00:00Z`);
  const off = new Intl.DateTimeFormat('en-US', { timeZone: 'America/Toronto', timeZoneName: 'shortOffset' }).formatToParts(probe).find((p) => p.type === 'timeZoneName')?.value.replace('GMT', '') || '-5';
  const from = new Date(`${s}T00:00:00${off.length <= 3 ? `${off[0]}${off.slice(1).padStart(2, '0')}:00` : off}`);
  return { from, to: new Date(from.getTime() + (DAYS[view ?? 'two'] ?? 14) * 86_400_000) };
}

