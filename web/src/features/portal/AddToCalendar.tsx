'use client';

// Downloads an .ics file built in the browser (02 section 7.2): pickup and return as two events.
export function AddToCalendar({ number, car, pickup, ret, place }: { number: string; car: string; pickup: string; ret: string; place: string }) {
  const stamp = (iso: string) => new Date(iso).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
  const ev = (uid: string, start: string, title: string) => [
    'BEGIN:VEVENT', `UID:${uid}@carmacars.ca`, `DTSTAMP:${stamp(new Date().toISOString())}`, `DTSTART:${stamp(start)}`,
    `DTEND:${stamp(new Date(new Date(start).getTime() + 30 * 60e3).toISOString())}`, `SUMMARY:${title}`, `LOCATION:${place.replace(/,/g, '\\,')}`, 'END:VEVENT'
  ].join('\r\n');
  const download = () => {
    const ics = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//CarmaCars//Booking//EN', ev(`${number}-pickup`, pickup, `Pick up ${car} (${number})`), ev(`${number}-return`, ret, `Return ${car} (${number})`), 'END:VCALENDAR'].join('\r\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([ics], { type: 'text/calendar' }));
    a.download = `${number}.ics`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  };
  return <button type="button" className="btn btn--ghost btn--sm" onClick={download}>Add to calendar</button>;
}
