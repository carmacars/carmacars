import { SlotPicture } from '@/components/Picture';
import { photoUrl } from '@/lib/photo';
import { isStandIn } from '@/lib/slot-cars';
import type { SlotPhoto } from '@/lib/types';
import type { StudioCover } from '@/lib/studio-covers';
import { FADE, STEP, heroKeyframes } from '@/features/home/hero-keyframes';

/** The neutral studio photo shown where no car has a passed studio render yet (release 50, 3701). */
export const STUDIO_PLACEHOLDER = '/studio/coming-soon.jpg';
/** The most cars the hero shows in turn. */
export const REEL_MAX = 6;

// Release 50 (3701). The owner (Nov 24): the hero and the home sections must show the same studio renders as the listings
// (the same cropped car, the same angle, the same plate). Before, these sections cut real cars out of whatever photo the
// cutout chain found (an owner's photo, a check-in photo, a stock photo) and stood them on a drawn plate, so the hero never
// matched the listings. Now a section that still has its built-in sample photo (the stand-in) shows the studio renders that
// passed the gate (app.site_studio_covers: the side profile, the cover of every listing), whole, in turn (6 seconds a car,
// a 1-second fade, pure CSS; reduced motion: the first); with none yet, the neutral studio photo. A section photo an
// Admin replaced in Site content is shown as it is.
export function SlotCars({ slot, photo, studio, eager = false, sizes = '100vw' }: { slot: string; photo: SlotPhoto | null; studio: readonly StudioCover[]; eager?: boolean; sizes?: string }) {
  if (photo && !isStandIn(slot, photo)) return <SlotPicture p={photo} eager={eager} sizes={sizes} />;
  const cars = studio.filter((c) => c.path).slice(0, REEL_MAX);
  if (!cars.length) {
    return (
      <span className="studio-reel" data-testid="studio-reel" data-slot={slot} data-count={0}>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={STUDIO_PLACEHOLDER} width={1800} height={1200} alt="" sizes={sizes} loading={eager ? 'eager' : 'lazy'} fetchPriority={eager ? 'high' : undefined} decoding="async" style={{ opacity: 1 }} />
      </span>
    );
  }
  const n = cars.length;
  return (
    <span className="studio-reel" data-testid="studio-reel" data-slot={slot} data-count={n} aria-hidden="true">
      {n > 1 && <style>{`${heroKeyframes(n)}.studio-reel[data-count="${n}"] img{animation:hero-slides-${n} ${n * STEP}s linear infinite}`}</style>}
      {cars.map((c, k) => (
        // eslint-disable-next-line @next/next/no-img-element
        <img key={c.path} src={photoUrl(c.path)} srcSet={c.variants?.length ? c.variants.map((v) => `${photoUrl(v.path)} ${v.width}w`).join(', ') : undefined}
          sizes={sizes} width={c.width ?? 1800} height={c.height ?? 1200} alt="" data-testid="slot-car"
          loading={eager && k === 0 ? 'eager' : 'lazy'} fetchPriority={eager && k === 0 ? 'high' : 'low'} decoding="async"
          style={n > 1 ? { animationDelay: `${k === 0 ? -FADE : k * STEP - FADE}s` } : { opacity: 1 }} />))}
    </span>
  );
}
