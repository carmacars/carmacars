import Link from '@/components/Link';
import './tracking.css';
import { when } from './model';
import { locationLine, mapLink, type CarLoc, type OwnerLoc } from './location';
import { eventLabel, mapUrl, type OwnerEvent } from './events';

// Release 48 (3041): where one car is. Staff (every role) on the car and booking pages, with a link to the car map; the
// owner on their car's page, with its trips (the location only). "No tracker yet" when the car has none.
export function CarLocation({ d, at, mapHref }: { d: CarLoc | null; at: number; mapHref?: string }) {
  if (!d) return <p className="small muted" data-testid="car-location">Where the car is could not be read. Reload the page.</p>;
  return (
    <div data-testid="car-location" data-tracker={d.tracker ? 'yes' : 'no'}>
      <p className={d.tracker ? '' : 'muted'}>{locationLine(d, at)}</p>
      {d.pos && <p className="small">{when(d.pos.at)} · <a className="link" href={mapLink(d.pos)} target="_blank" rel="noopener noreferrer" data-testid="car-location-map">Open on the map</a>
        {mapHref && <> · <Link prefetch={false} className="link" href={mapHref}>Car map</Link></>}</p>}
    </div>
  );
}

export function OwnerCarLocation({ d, at }: { d: OwnerLoc | null; at: number }) {
  if (!d) return <p className="small muted" data-testid="owner-car-location">Where your car is could not be read. Reload the page.</p>;
  return (
    <div data-testid="owner-car-location" data-tracker={d.tracker ? 'yes' : 'no'}>
      <CarLocation d={d} at={at} />
      {d.tracker && (d.trips.length
        ? <><h3 className="h6 mt-h">Trips in the last {d.days} days</h3>
          <ul className="small" data-testid="owner-trips">{d.trips.map((t) => (
            <li key={t.id}>{when(t.started_at)}: {t.km} km
              {t.from && <> · <a className="link" href={mapLink(t.from)} target="_blank" rel="noopener noreferrer">start</a></>}
              {t.to && <> · <a className="link" href={mapLink(t.to)} target="_blank" rel="noopener noreferrer">end</a></>}</li>))}</ul></>
        : <p className="small muted">No trips in the last {d.days} days.</p>)}
      {d.tracker && <p className="small muted">You see your car&apos;s location and trips only, never the renter or the booking.</p>}
    </div>
  );
}

// Tracker events (3320): what the tracker recorded on the owner's own car in the last days. The event, the time and the
// place only (the database leaves the renter and the booking out); "nothing recorded" when there is none.
export function OwnerTrackerEvents({ d }: { d: { days: number; events: OwnerEvent[] } | null }) {
  if (!d) return <p className="small muted" data-testid="owner-tracker-events">The tracker alerts could not be read. Reload the page.</p>;
  if (!d.events.length) return <p className="small muted" data-testid="owner-tracker-events">Nothing recorded in the last {d.days} days: no speeding, harsh driving, tampering or pound alerts. We tell you by email, text or the app when there is one, as your notification settings say.</p>;
  return (
    <div data-testid="owner-tracker-events">
      <ul className="te-owner">{d.events.map((e) => (
        <li key={e.id} data-kind={e.kind}>
          <b>{e.title ?? eventLabel(e)}</b>
          <span className="small">{e.what}</span>
          <span className="small muted">{when(e.at)}{mapUrl(e) && <> · <a className="link" href={mapUrl(e)!} target="_blank" rel="noopener noreferrer">See the place</a></>}</span>
        </li>))}</ul>
      <p className="small muted">CarmaCars handles each one with the renter. You see the event and the place only, never the renter or the booking. Turn these alerts on or off in your <Link prefetch={false} className="link" href="/owner/notifications">notification settings</Link>.</p>
    </div>
  );
}
