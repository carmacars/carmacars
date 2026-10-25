import 'server-only';
import { cache } from 'react';
import { absUrl } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { approxNote, credit, heightAt, imageObjectLd, largest, photoAlt, pickFor, sizePath, srcSet, type GenericPhoto, type StockPhoto } from './stock-photos';

// The licensed stock photos on the pages (migration 0149; docs/changes/2026-10-24-seo-photos.md): one read per page
// (shared by the metadata and the page through React's cache), the figure with its always-visible credit, and the
// ImageObject for the structured data. A page with no photo (or before the migration) keeps the studio drawing.
// Our fleet's cars always show their own photos (the inventory below); these photos are never of our cars.

const ok = (p: unknown): p is StockPhoto => !!p && typeof p === 'object' && typeof (p as StockPhoto).path === 'string' && Array.isArray((p as StockPhoto).sizes) && (p as StockPhoto).sizes.length > 0
  && Number((p as StockPhoto).width) > 0 && Number((p as StockPhoto).height) > 0 && typeof (p as StockPhoto).source_url === 'string';

/** The photo of a make (its most popular model), a model (its newest generation) or a model year (that generation only). */
export const stockPhoto = cache(async (make: string, model: string | null = null, year: number | null = null): Promise<StockPhoto | null> => {
  try {
    const p = await rpc('vehicle_stock_photo', { p_make: make, p_model: model as string, p_year: year as number });
    return ok(p) ? p : null;
  } catch { return null; }
});

/** One of the generic photos of a kind of place or service page (rental, detailing, bodyshop, sale), the same for the same address. */
export const genericPhoto = cache(async (slot: string, key: string): Promise<GenericPhoto | null> => {
  try {
    const list = (await rpc('stock_photos_generic', { p_slot: slot })) as unknown;
    return pickFor((Array.isArray(list) ? list : []).filter(ok) as unknown as GenericPhoto[], key);
  } catch { return null; }
});

export const photoSrc = (p: { path: string; sizes: number[] }) => absUrl(sizePath(p, largest(p)));
/** The sharing image (og:image) of a page with a photo: the largest width, its real size. */
export const photoShare = (p: StockPhoto | GenericPhoto) => ({ url: photoSrc(p), size: [largest(p), heightAt(p, largest(p))] as [number, number] });
export const photoLd = (p: StockPhoto | GenericPhoto, caption?: string) => imageObjectLd(p, absUrl, caption);
export const stockAlt = (p: StockPhoto) => photoAlt(p);
/** The note under a vehicle page's photo: not one of our cars, and, when it is not of the page's year, which it is. */
export const stockNote = (p: StockPhoto) => { const a = approxNote(p); return a ? `${a}; not one of our cars` : 'Representative photo, not one of our cars'; };

/** The credit line, always visible: "Photo: <author>, <licence>, <source>", linking to the file and the licence. */
export function PhotoCredit({ p, note }: { p: StockPhoto | GenericPhoto; note?: string }) {
  const c = credit(p);
  return (
    <figcaption className="vp-photo__credit" data-testid="photo-credit">
      Photo: <a className="link" href={c.source} target="_blank" rel="noopener">{c.author}</a>,{' '}
      {c.licenceUrl ? <a className="link" href={c.licenceUrl} target="_blank" rel="license noopener">{c.licence}</a> : c.licence}, {c.where}{note ? `. ${note}` : ''}
    </figcaption>
  );
}

/** The figure: a responsive srcset, the photo's own width and height (no layout shift), lazy unless it is the page's
 *  main image (the head of a vehicle page: loaded first, as the studio drawing it replaces was). */
export function StockFigure({ p, alt, className = '', main = false, sizes = '(min-width: 64rem) 50vw, 100vw', note }: { p: StockPhoto | GenericPhoto; alt: string; className?: string; main?: boolean; sizes?: string; note?: string }) {
  const w = largest(p);
  return (
    <figure className={`vp-photo ${className}`.trim()} data-testid="stock-photo">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src={absUrl(sizePath(p, w))} srcSet={srcSet(p, absUrl)} sizes={sizes} width={w} height={heightAt(p, w)} alt={alt} decoding="async"
        {...(main ? { fetchPriority: 'high' as const } : { loading: 'lazy' as const })} />
      <PhotoCredit p={p} note={note} />
    </figure>
  );
}
