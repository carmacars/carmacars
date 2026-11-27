'use client';
import { useEffect, useRef } from 'react';

// Add to calendar (02 section 7.2; r50 hotfix 2: one menu for every calendar). Apple Calendar and any other app take the
// .ics file built here in the browser (pickup and return as two events, each with a reminder); Google Calendar and
// Outlook open their own new-event page with the pickup filled in. Nothing is sent to us.
const stamp = (iso: string) => new Date(iso).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
const esc = (t: string) => t.replace(/\\/g, '\\\\').replace(/;/g, '\;').replace(/,/g, '\\,').replace(/\n/g, '\\n');
const plus = (iso: string, min: number) => new Date(new Date(iso).getTime() + min * 60e3).toISOString();

export interface CalendarEvent { uid: string; title: string; start: string; minutes: number; place: string; details: string }

/** The .ics text of the events (pure: unit tested). */
export function icsOf(events: CalendarEvent[], now = new Date().toISOString()): string {
  const ev = (e: CalendarEvent) => ['BEGIN:VEVENT', `UID:${e.uid}@carmacars.ca`, `DTSTAMP:${stamp(now)}`, `DTSTART:${stamp(e.start)}`, `DTEND:${stamp(plus(e.start, e.minutes))}`,
    `SUMMARY:${esc(e.title)}`, `LOCATION:${esc(e.place)}`, `DESCRIPTION:${esc(e.details)}`,
    'BEGIN:VALARM', 'ACTION:DISPLAY', `DESCRIPTION:${esc(e.title)}`, 'TRIGGER:-PT2H', 'END:VALARM', 'END:VEVENT'].join('\r\n');
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//CarmaCars//Booking//EN', 'CALSCALE:GREGORIAN', ...events.map(ev), 'END:VCALENDAR'].join('\r\n') + '\r\n';
}
/** Google Calendar's new-event link (pure). */
export function googleLink(e: CalendarEvent): string {
  const q = new URLSearchParams({ action: 'TEMPLATE', text: e.title, dates: `${stamp(e.start)}/${stamp(plus(e.start, e.minutes))}`, location: e.place, details: e.details });
  return `https://calendar.google.com/calendar/render?${q.toString()}`;
}
/** Outlook's new-event link (pure). */
export function outlookLink(e: CalendarEvent): string {
  const q = new URLSearchParams({ path: '/calendar/action/compose', rru: 'addevent', subject: e.title, startdt: new Date(e.start).toISOString(), enddt: plus(e.start, e.minutes), location: e.place, body: e.details });
  return `https://outlook.live.com/calendar/0/deeplink/compose?${q.toString()}`;
}

export function AddToCalendar({ number, car, pickup, ret, place, testId = 'add-to-calendar' }: { number: string; car: string; pickup: string; ret: string; place: string; testId?: string }) {
  const box = useRef<HTMLDetailsElement>(null);
  const page = typeof window === 'undefined' ? '' : `${window.location.origin}/account/bookings/${number}`;
  const events: CalendarEvent[] = [
    { uid: `${number}-pickup`, title: `Pick up ${car} (${number})`, start: pickup, minutes: 30, place, details: `CarmaCars booking ${number}. Bring your original licence and the card you paid with.${page ? ` ${page}` : ''}` },
    { uid: `${number}-return`, title: `Return ${car} (${number})`, start: ret, minutes: 30, place, details: `CarmaCars booking ${number}. Return it with the same fuel or charge.${page ? ` ${page}` : ''}` }
  ];
  useEffect(() => {
    const d = box.current;
    if (!d) return;
    const out = (e: MouseEvent) => { if (d.open && !d.contains(e.target as Node)) d.open = false; };
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape' && d.open) { d.open = false; d.querySelector('summary')?.focus(); } };
    document.addEventListener('click', out);
    d.addEventListener('keydown', key);
    return () => { document.removeEventListener('click', out); d.removeEventListener('keydown', key); };
  }, []);
  const download = () => {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([icsOf(events)], { type: 'text/calendar' }));
    a.download = `${number}.ics`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    if (box.current) box.current.open = false;
  };
  return (
    <details ref={box} className="cal-menu" data-testid={testId}>
      <summary className="btn btn--ghost btn--sm" data-testid={`${testId}-open`}>Add to calendar</summary>
      <div className="cal-menu__list" role="menu" aria-label="Add your pickup and return to a calendar">
        <button type="button" role="menuitem" className="cal-menu__item" onClick={download} data-testid={`${testId}-apple`}><b>Apple Calendar</b><small>iPhone, iPad and Mac: pickup and return</small></button>
        <a role="menuitem" className="cal-menu__item" href={googleLink(events[0]!)} target="_blank" rel="noopener noreferrer" data-testid={`${testId}-google`}><b>Google Calendar</b><small>Opens Google with your pickup filled in</small></a>
        <a role="menuitem" className="cal-menu__item" href={outlookLink(events[0]!)} target="_blank" rel="noopener noreferrer" data-testid={`${testId}-outlook`}><b>Outlook</b><small>Opens Outlook with your pickup filled in</small></a>
        <button type="button" role="menuitem" className="cal-menu__item" onClick={download} data-testid={`${testId}-ics`}><b>Other calendars (.ics)</b><small>A file any calendar app opens</small></button>
      </div>
    </details>
  );
}
