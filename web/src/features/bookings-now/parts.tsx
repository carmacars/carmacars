import './bookings-now.css';
import Link from '@/components/Link';
import type { ReactNode } from 'react';
import { photoUrl } from '@/lib/photo';
import { initial, phoneHref, photoPath, type Car, type Renter } from './model';
import { ContactButtons } from '@/features/phone/QuoButtons';

// The pieces every Bookings screen shares (Now, Requests and offers, All bookings, the Calendar; admin and staff alike):
// the dark count tiles, the car with its photo, the renter with Call and Text, a time with its countdown, a status chip.
// No state, so server pages and client components use the same ones.

export function Tile({ k, href, label, n, note, urgent, current }: { k: string; href: string; current?: boolean; label: string; n: number; note: ReactNode; urgent?: boolean }) {
  return (
    <li><a aria-current={current ? 'page' : undefined} className={`bn-tile${current ? ' is-current' : ''}${urgent ? ' is-urgent' : ''}${n === 0 ? ' is-zero' : ''}`} href={href} data-testid={`bn-tile-${k}`}>
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

export function Who({ r, booking }: { r: Renter | null; booking?: string | null }) {
  if (!r) return <span className="bn-who muted">No renter</span>;
  // r27 consolidation: Call and Text through Quo (features/phone/QuoButtons.tsx; tel: and sms: when Quo is off)
  const tel = phoneHref(r.phone, 'tel');
  return (
    <span className="bn-who">
      <span className="bn-who__name">{r.name}</span>
      {tel && <span className="bn-who__acts"><ContactButtons phone={r.phone} name={r.name} booking={booking} look="icons" testId="bn-contact" /></span>}
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
