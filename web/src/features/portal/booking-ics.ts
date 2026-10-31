// A booking's pickup and return as two calendar events (Release 22: the confirmation email's link; the booking page builds
// the same in the browser). No imports: Worker and `node --test`.
const esc = (s: string) => s.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
const stamp = (iso: string) => new Date(iso).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');

export function bookingIcs(b: { number: string; car: string; pickup_at: string; return_at: string; pickup_place: string; return_place?: string | null }, now = new Date()): string {
  const ev = (uid: string, start: string, title: string, place: string) => ['BEGIN:VEVENT', `UID:${uid}@carmacars.ca`, `DTSTAMP:${stamp(now.toISOString())}`, `DTSTART:${stamp(start)}`,
    `DTEND:${stamp(new Date(new Date(start).getTime() + 30 * 60e3).toISOString())}`, `SUMMARY:${esc(title)}`, `LOCATION:${esc(place)}`, 'END:VEVENT'].join('\r\n');
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//CarmaCars//Booking//EN', 'METHOD:PUBLISH',
    ev(`${b.number}-pickup`, b.pickup_at, `Pick up ${b.car} (${b.number})`, b.pickup_place),
    ev(`${b.number}-return`, b.return_at, `Return ${b.car} (${b.number})`, b.return_place || b.pickup_place), 'END:VCALENDAR', ''].join('\r\n');
}
