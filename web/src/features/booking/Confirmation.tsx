'use client';
import { useSyncExternalStore } from 'react';
import { clock, longDate } from '@/lib/dates';
import { money } from '@/lib/format';

// What the person asked for, kept in this tab by the wizard right after sending (nothing is read
// back from the database: requests are private). The request number is in the address.
type Last = { number: string; car: string; from: string; to: string; tf: string; tt: string; deliver: boolean; total: number | null; deposit: number | null; days: number | null; email: string; first: string; coverage: string };

export function useLast(number: string) {
  const raw = useSyncExternalStore(() => () => {}, () => { try { return sessionStorage.getItem('cc.lastRequest'); } catch { return null; } }, () => undefined);
  if (raw === undefined) return undefined;
  try { const v = JSON.parse(raw ?? 'null') as Last | null; return v && v.number === number ? v : null; } catch { return null; }
}

export function ConfName({ number }: { number: string }) { const r = useLast(number); return <>{r?.first ? `, ${r.first}` : ''}</>; }
export function ConfEmail({ number }: { number: string }) { const r = useLast(number); return r?.email ? <> to <b>{r.email}</b></> : null; }
export function ConfCoverage({ number }: { number: string }) {
  const r = useLast(number);
  if (!r) return null;
  return <>{r.coverage === '1' && ' For option 1, add the policy page or insurer letter that shows OPCF 27.'}{r.coverage === '2' && ' For option 2, add your card’s benefits certificate, and pay with that card.'}{r.coverage === '3' && ' For option 3, we send the Protection Plan’s terms and activate it once it is paid.'}</>;
}
export function ConfRows({ number, depLead }: { number: string; depLead: string }) {
  const r = useLast(number);
  if (r === undefined) return null;
  if (!r) return <p className="alert"><span className="alert__title">Your request is with us</span><span>The details are in the email we send you. Keep your request number for any question.</span></p>;
  const rows: [string, string][] = [
    ['Car', r.car], ['Pickup', `${longDate(r.from)}, ${clock(r.tf)}${r.deliver ? ', delivered' : ''}`], ['Return', `${longDate(r.to)}, ${clock(r.tt)}`],
    ...(r.days ? [['Length', `${r.days} ${r.days === 1 ? 'day' : 'days'}`] as [string, string]] : []),
    ...(r.total !== null ? [['Estimated total', `${money(r.total, { cents: true })} with HST. Not charged.`] as [string, string]] : []),
    ...(r.deposit !== null ? [[`Deposit, about ${depLead} before pickup`, money(r.deposit)] as [string, string]] : [])
  ];
  return <div className="stack"><h2 className="d4">What you asked for</h2><table className="spec"><tbody>{rows.map(([k, v]) => <tr key={k}><th scope="row">{k}</th><td>{v}</td></tr>)}</tbody></table></div>;
}

/** r50 (3900): Book instantly was chosen but the car could not be booked at once: it came to us as a request (?instant=no). */
export function ConfInstantNo() {
  const no = useSyncExternalStore(() => () => {}, () => { try { return new URLSearchParams(window.location.search).get('instant') === 'no'; } catch { return false; } }, () => false);
  if (!no) return null;
  return <p className="alert alert--info" data-testid="sent-instant-no"><span className="alert__title">Sent as a request</span><span>This car could not be booked instantly just now, so your booking came to us as a request. Nothing is charged: we reply with a pay link or an offer, by email and text.</span></p>;
}
