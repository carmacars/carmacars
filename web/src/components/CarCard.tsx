import Link from '@/components/Link';
import type { CarRow } from '@/lib/types';
import { money, FUEL_LABEL } from '@/lib/format';
import { CarImage } from './Picture';
import { photoUrl } from '@/lib/photo';

export const carName = (c: Pick<CarRow, 'make' | 'model'>) => `${c.make} ${c.model}`;
export const classLabel = (codes: string[], labels: Record<string, string>) => codes.map((c) => labels[c] ?? c).join(', ');

// The car card of prototype/DESIGN.md: 3:2 photo, name and price in Inter Display, spec line.
// When the fleet has dates, `price` and `unit` carry the quote from the database. A sample car (0065) says "Example car".
// `photosMax` is how many photos it may show, the cover included (at most 5, never past the free photos of the phone number box).
// R50 (5030, docs/changes/2026-11-25-r50-car-cards.md): the card's photos are the car's studio renders, the side profile
// first. A phone swipes them natively (a scroll-snap track, one photo a snap); a mouse moving across the photo shows photo
// 1..N by where it is; arrow keys on the focused card do the same. A click or tap on a car whose side render has its matte
// drives the car off its studio floor as the car page opens (src/lib/card-photos.ts, src/styles/car-card.css). Only the
// first photo loads with the page: the slides after it are filled when the card is about to be used.
export function CarCard({ c, labels, tag: Tag = 'h3', href, price, unit, booked = false, photosMax }: {
  c: CarRow; labels: Record<string, string>; tag?: 'h2' | 'h3'; href?: string; price?: string; unit?: string; booked?: boolean; photosMax?: number;
}) {
  const real = !!c.cover && !c.cover.sample && !c.cover.placeholder;
  const n = real ? Math.max(1, Math.min(photosMax ?? 5, 5, c.rendered ?? 1)) : 1;
  const cut = real ? c.cover!.cutout : null;
  const matte = cut?.kind === 'matte' && cut.plate && cut.box ? cut : null;
  return (
    <article className="car-card" data-slug={n > 1 ? c.slug : undefined} data-n={n > 1 ? n : undefined}
      data-matte={matte ? photoUrl(matte.path) : undefined} data-plate={matte ? photoUrl(matte.plate!) : undefined}
      data-box={matte ? [matte.box!.x, matte.box!.y, matte.box!.w, matte.box!.h].join(',') : undefined}
      data-facing={matte ? matte.facing : undefined}>
      <div className="car-card__media photo photo--32" data-wm={real ? '' : undefined}>
        <div className="car-card__track" data-testid="card-track">
          <div className="car-card__slide is-on"><CarImage p={c.cover} /></div>
          {/* the other photos: filled by card-photos.ts, never by React (an empty innerHTML React leaves alone) */}
          {Array.from({ length: n - 1 }, (_, i) => <div key={i} className="car-card__slide" data-i={i + 1} dangerouslySetInnerHTML={{ __html: '' }} />)}
        </div>
        {n > 1 && <span className="car-card__dots" aria-hidden="true">{Array.from({ length: n }, (_, i) => <i key={i} className={i === 0 ? 'is-on' : undefined} />)}</span>}
        {/* r50 (3701): only the car's own studio renders, or one neutral "Photos coming soon" photo; never another car's photo */}
        {c.cover?.placeholder && <span className="car-card__sample" data-testid="photos-coming-soon">Photos coming soon</span>}
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
