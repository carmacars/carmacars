import './bookings-now.css';
import Link from 'next/link';
import type { ReactNode } from 'react';
import { photoUrl } from '@/lib/photo';
import { initial, phoneHref, photoPath, type Car, type Renter } from './model';

// The pieces every Bookings screen shares (Now, Requests and offers, All bookings, the Calendar; admin and staff alike):
// the dark count tiles, the car with its photo, the renter with Call and Text, a time with its countdown, a status chip.
// No state, so server pages and client components use the same ones.

export function Tile({ k, href, label, n, note, urgent }: { k: string; href: string; label: string; n: number; note: ReactNode; urgent?: boolean }) {
  return (
    <li><a className={`bn-tile${urgent ? ' is-urgent' : ''}${n === 0 ? ' is-zero' : ''}`} href={href} data-testid={`bn-tile-${k}`}>
      <span className="bn-tile__label">{label}</span><b className="bn-tile__n">{n}</b><span className="bn-tile__note">{urgent && <span className="vh">Needs you: </span>}{note}</span>
    </a></li>
  );
}

export function Photo({ car, size }: { car: Car; size: number }) {
  const p = photoPath(car.photo, size * 2);
  return p
    // eslint-disable-next-line @next/next/no-img-element -- the listing photos come pre-sized (0149's variants)
    ? <img className="bn-photo" src={photoUrl(p)} alt="" width={size} height={Math.round(size * 0.66)} loading="lazy" decoding="async" />
    : <span className="bn-photo bn-photo--none" aria-hidden="true">{initial(car.name)}</span>;
}

export function CarLine({ car, number, href, compact }: { car: Car; number: string; href: string | null; compact?: boolean }) {
  const id = [car.code, car.plate].filter(Boolean).join(' · ');
  return (
    <span className={`bn-carline${compact ? ' is-compact' : ''}`}>
      {!compact && <Photo car={car} size={56} />}
      <span className="bn-carline__text">
        <span className="bn-carline__name">{car.name}</span>
        <span className="bn-carline__id">{id}{id && number ? ' · ' : ''}{number ? href ? <Link prefetch={false} href={href} className="bn-link">{number}</Link> : number : null}</span>
      </span>
    </span>
  );
}

export function Who({ r }: { r: Renter | null }) {
  if (!r) return <span className="bn-who muted">No renter</span>;
  const tel = phoneHref(r.phone, 'tel'), sms = phoneHref(r.phone, 'sms');
  return (
    <span className="bn-who">
      <span className="bn-who__name">{r.name}</span>
      {(tel || sms) && <span className="bn-who__acts">
        {tel && <a className="bn-icon" href={tel} aria-label={`Call ${r.name}`} title={`Call ${r.phone}`}><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M6.6 2.5 4.4 3.1c-.8.2-1.3 1-1.2 1.8.6 6.1 5.7 11.2 11.8 11.8.8.1 1.6-.4 1.8-1.2l.6-2.2-3.4-1.5-1.5 1.6a9 9 0 0 1-4.6-4.6l1.6-1.5z" /></svg></a>}
        {sms && <a className="bn-icon" href={sms} aria-label={`Text ${r.name}`} title={`Text ${r.phone}`}><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3.5 4.5h13v9h-7l-4 3v-3h-2z" /></svg></a>}
      </span>}
    </span>
  );
}

export function Time({ big, small, late }: { big: string; small: string; late: boolean }) {
  return <span className={`bn-time${late ? ' is-late' : ''}`}><b>{big}</b><span>{small}</span></span>;
}


/** A small status chip in plain words; tone: red (needs someone now), dark, amber (waiting on someone), ok, quiet. */
export function Chip({ tone = 'quiet', children, testId }: { tone?: 'red' | 'dark' | 'amber' | 'ok' | 'quiet'; children: ReactNode; testId?: string }) {
  return <span className={`bn-chip-s bn-chip-s--${tone}`} data-testid={testId}>{children}</span>;
}

/** The count tiles on black, as at the top of Now. */
export function TileBand({ label, children }: { label: string; children: ReactNode }) {
  return <ul className="bn-sum" aria-label={label}>{children}</ul>;
}
