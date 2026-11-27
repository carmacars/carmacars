// A booking's pickup and return as two calendar events (Release 22: the confirmation email's link; the booking page builds
// the same in the browser). No imports: Worker and `node --test`.
const esc = (s: string) => s.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
export const icsStamp = (iso: string) => new Date(iso).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');

export function bookingIcs(b: { number: string; car: string; pickup_at: string; return_at: string; pickup_place: string; return_place?: string | null }, now = new Date()): string {
  const ev = (uid: string, start: string, title: string, place: string) => ['BEGIN:VEVENT', `UID:${uid}@carmacars.ca`, `DTSTAMP:${icsStamp(now.toISOString())}`, `DTSTART:${icsStamp(start)}`,
    `DTEND:${icsStamp(new Date(new Date(start).getTime() + 30 * 60e3).toISOString())}`, `SUMMARY:${esc(title)}`, `LOCATION:${esc(place)}`, 'END:VEVENT'].join('\r\n');
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//CarmaCars//Booking//EN', 'METHOD:PUBLISH',
    ev(`${b.number}-pickup`, b.pickup_at, `Pick up ${b.car} (${b.number})`, b.pickup_place),
    ev(`${b.number}-return`, b.return_at, `Return ${b.car} (${b.number})`, b.return_place || b.pickup_place), 'END:VCALENDAR', ''].join('\r\n');
}

export interface CalendarEvent { uid: string; title: string; start: string; minutes: number; place: string; details: string }
const plus = (iso: string, min: number) => new Date(new Date(iso).getTime() + min * 60e3).toISOString();

/** The Add to calendar file (r50 hotfix 2): each event with a reminder 2 hours before. */
export function icsOf(events: CalendarEvent[], now = new Date().toISOString()): string {
  const ev = (e: CalendarEvent) => ['BEGIN:VEVENT', `UID:${e.uid}@carmacars.ca`, `DTSTAMP:${icsStamp(now)}`, `DTSTART:${icsStamp(e.start)}`, `DTEND:${icsStamp(plus(e.start, e.minutes))}`,
    `SUMMARY:${esc(e.title)}`, `LOCATION:${esc(e.place)}`, `DESCRIPTION:${esc(e.details)}`,
    'BEGIN:VALARM', 'ACTION:DISPLAY', `DESCRIPTION:${esc(e.title)}`, 'TRIGGER:-PT2H', 'END:VALARM', 'END:VEVENT'].join('\r\n');
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//CarmaCars//Booking//EN', 'CALSCALE:GREGORIAN', ...events.map(ev), 'END:VCALENDAR'].join('\r\n') + '\r\n';
}
