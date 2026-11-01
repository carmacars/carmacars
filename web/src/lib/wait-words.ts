// How long something has waited, in one plain format everywhere (the owner, Release 26: "Waiting 27294 minutes 18d 22h"
// was printed twice in two formats): "under a minute", "12 min", "3 h", "1 day", "18 days".
export function waitWords(minutes: number): string {
  const m = Math.max(0, Math.floor(minutes));
  if (m < 1) return 'under a minute';
  if (m < 60) return `${m} min`;
  if (m < 1440) return `${Math.floor(m / 60)} h`;
  const d = Math.floor(m / 1440);
  return d === 1 ? '1 day' : `${d} days`;
}
