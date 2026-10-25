// Time in words for the portals (portal-ui), shared by the server and the live countdown.
/** "2 days 4 h", "5 h 20 min", "12 min": the time between now and an instant, in words. */
export function span(ms: number): string {
  const m = Math.max(1, Math.round(Math.abs(ms) / 60e3));
  const d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60), min = m % 60;
  if (d >= 2) return `${d} days${h ? ` ${h} h` : ''}`;
  if (d === 1) return `1 day${h ? ` ${h} h` : ''}`;
  if (h) return `${h} h${min ? ` ${min} min` : ''}`;
  return `${min} min`;
}

