// Release 26 (the Visitors page's "Show contact", off): the live visits with no phone or email anywhere, the names
// kept. Used by /api/staff/live (contact=0), the Visitors page as the server draws it, and Live now in the browser. No
// imports but types, so the unit tests run it as it is and the server may call it.
import type { LiveData, Visitor } from './staff';

/** A visit with no phone or email anywhere, the names kept. A visitor known only by an email or a phone shows as
 * "Visitor in <city>". */
export function visitorWithoutContact<V extends Visitor>(v: V): V {
  const hidden = (s: string | null | undefined) => !!s && /@|\d{7,}/.test(s.replace(/[\s().+-]/g, ''));
  return {
    ...v, email: null,
    who: hidden(v.who) ? (v.city ? `Visitor in ${v.city}` : 'Visitor') : v.who,
    captured: v.captured ? { ...v.captured, email: null, phone: null, name: hidden(v.captured.name) ? null : v.captured.name } : v.captured,
    label: v.label ? { ...v.label, email: null, phone: null } : v.label
  };
}
export function liveWithoutContact(d: LiveData): LiveData {
  return { ...d, now: d.now.map(visitorWithoutContact), hot: d.hot?.map((h) => (/@/.test(h.who) ? { ...h, who: 'Visitor' } : h)),
    signals: d.signals.map((s) => (s.who && /@/.test(s.who) ? { ...s, who: 'Visitor' } : s)) };
}
