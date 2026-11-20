import Link from '@/components/Link';
import type { CarRow } from '@/lib/types';
import { money, FUEL_LABEL } from '@/lib/format';
import { CarImage, StudioTurn } from './Picture';
import { photoUrl } from '@/lib/photo';
import { DriveFrame } from '@/portable/motion/react';

export const carName = (c: Pick<CarRow, 'make' | 'model'>) => `${c.make} ${c.model}`;
export const classLabel = (codes: string[], labels: Record<string, string>) => codes.map((c) => labels[c] ?? c).join(', ');

// The car card of prototype/DESIGN.md: 3:2 photo, name and price in Inter Display, spec line.
// When the fleet has dates, `price` and `unit` carry the quote from the database. A sample car (0065) says "Example car".
// 2026-11-06: hovering the card shows the car's other photos in turn, and a swipe on a card in a grid moves through them
// (src/lib/card-photos.ts fills the empty deck on first hover; React never touches what it adds). `photosMax` is how many
// photos it may show, the cover included (at most 5, never past the free photos of the phone number box).
// r48 AN (3150): a car whose cover has its side cutout stands on the card's studio floor; hovering (desktop), or the card
// coming into view (touch), drives the car off the side of the frame while the floor stays, then it eases back in
// (src/portable/motion). No cutout yet: the cover photo and the card's gentle lift, as before.
export function CarCard({ c, labels, tag: Tag = 'h3', href, price, unit, booked = false, photosMax }: {
  c: CarRow; labels: Record<string, string>; tag?: 'h2' | 'h3'; href?: string; price?: string; unit?: string; booked?: boolean; photosMax?: number;
}) {
  const cut = c.cover && !c.cover.sample && c.cover.cutout?.path ? c.cover.cutout : null;
  return (
    <article className="car-card" data-mo-drive-host={cut ? '' : undefined}>
      <div className="car-card__media photo photo--32" data-wm={c.cover && !c.cover.sample ? "" : undefined}>
        {!cut && <CarImage p={c.cover} />}
        {cut && <DriveFrame className="car-stage" src={photoUrl(cut.path)} width={cut.width ?? undefined} height={cut.height ?? undefined}
          sizes="(min-width: 64rem) 33vw, 100vw" alt={c.cover!.alt} facing={cut.facing} />}
        {c.cover?.sample && c.studio && c.studio.length > 0 && <StudioTurn photos={c.studio} />}
        {c.cover && !c.cover.sample && !cut && (photosMax ?? 5) > 1
          && <span className="car-card__deck" data-slug={c.slug} data-max={photosMax} aria-hidden="true" dangerouslySetInnerHTML={{ __html: '' }} />}
        {c.cover?.sample && <span className="car-card__sample" data-testid="sample-photo-caption">Representative photo</span>}
        {c.is_sample && <span className="car-card__example" data-testid="example-car-badge" title="An example of the cars we rent: ask and we suggest a similar real car">Example car</span>}
        {booked && <span className="badge badge--hatch car-card__flag">Booked for your dates</span>}
        {c.hot && !booked && <span className="car-card__hot" data-testid="car-card-hot">Hot</span>}
      </div>
      <div className="car-card__body">
        <Tag className="car-card__name"><Link prefetch={false} href={href ?? `/cars/${c.slug}`}>{c.make} <span>{c.model}</span></Link></Tag>
        <p className="car-card__meta">{[c.year, c.trim].filter(Boolean).join(' ')}{c.car_code && <span data-testid="car-card-code"> · Car code {c.car_code}</span>}</p>
        {c.insurance_included && <p className="car-card__perk" data-testid="car-card-perk">Insurance included{c.no_credit_card ? ', no credit card needed' : ''}</p>}
        <p className="car-card__price"><b className="num">{price ?? money(c.daily_rate_cents)}</b><span>{unit ?? 'a day'}</span></p>
        <ul className="car-card__specs">
          <li>{classLabel(c.classes, labels)}</li>
          {c.seats && <li>{c.seats} seats</li>}
          {c.transmission && <li>{c.transmission}</li>}
          <li>{FUEL_LABEL[c.fuel] ?? c.fuel}</li>
        </ul>
      </div>
    </article>
  );
}
