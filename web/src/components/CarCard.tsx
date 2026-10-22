import Link from 'next/link';
import type { CarRow } from '@/lib/types';
import { money, FUEL_LABEL } from '@/lib/format';
import { CarImage } from './Picture';

export const carName = (c: Pick<CarRow, 'make' | 'model'>) => `${c.make} ${c.model}`;
export const classLabel = (codes: string[], labels: Record<string, string>) => codes.map((c) => labels[c] ?? c).join(', ');

// The car card of prototype/DESIGN.md: 3:2 photo, name and price in Inter Display, spec line.
// When the fleet has dates, `price` and `unit` carry the quote from the database. A sample car (0065) says "Example car".
export function CarCard({ c, labels, tag: Tag = 'h3', href, price, unit, booked = false }: {
  c: CarRow; labels: Record<string, string>; tag?: 'h2' | 'h3'; href?: string; price?: string; unit?: string; booked?: boolean;
}) {
  return (
    <article className="car-card">
      <div className="car-card__media photo photo--32">
        <CarImage p={c.cover} />
        {c.cover?.sample && <span className="car-card__sample" data-testid="sample-photo-caption">Representative photo</span>}
        {c.is_sample && <span className="car-card__example" data-testid="example-car-badge" title="An example of the cars we rent: ask and we suggest a similar real car">Example car</span>}
        {booked && <span className="badge badge--hatch car-card__flag">Booked for your dates</span>}
      </div>
      <div className="car-card__body">
        <Tag className="car-card__name"><Link prefetch={false} href={href ?? `/cars/${c.slug}`}>{c.make} <span>{c.model}</span></Link></Tag>
        <p className="car-card__meta">{[c.year, c.trim].filter(Boolean).join(' ')}{c.car_code && <span data-testid="car-card-code"> · Car code {c.car_code}</span>}</p>
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
