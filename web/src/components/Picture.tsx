import type { SlotPhoto, Photo } from '@/lib/types';
import { photoUrl } from '@/lib/photo';

// Images come pre-sized from the photo pipeline (docs/blueprint/09-listing-pipeline.md); nothing is
// resized in the Worker. Width and height are always set; the page's largest image is never lazy.
export function SlotPicture({ p, eager = false, sizes = '100vw', alt }: { p: SlotPhoto | null; eager?: boolean; sizes?: string; alt?: string }) {
  if (!p) return null;
  return (
    <picture>
      <source media="(min-width: 48rem)" srcSet={photoUrl(p.wide.path)} width={p.wide.width} height={p.wide.height} />
      <img src={photoUrl(p.tall.path)} width={p.tall.width} height={p.tall.height} alt={alt ?? p.alt} sizes={sizes}
        loading={eager ? 'eager' : 'lazy'} fetchPriority={eager ? 'high' : undefined} decoding="async" />
    </picture>
  );
}

export function CarImage({ p, eager = false, sizes = '(min-width: 64rem) 33vw, 100vw', alt, width = 1800, height = 1200 }: { p: Photo | null; eager?: boolean; sizes?: string; alt?: string; width?: number; height?: number }) {
  if (!p) return <div className="skeleton sk-img" aria-hidden="true" />;
  const srcSet = p.variants?.length ? p.variants.map((v) => `${photoUrl(v.path)} ${v.width}w`).join(', ') : undefined;
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img src={photoUrl(p.path)} srcSet={srcSet} sizes={sizes} width={p.width ?? width} height={p.height ?? height} alt={alt ?? p.alt}
      loading={eager ? 'eager' : 'lazy'} fetchPriority={eager ? 'high' : undefined} decoding="async" />
  );
}
