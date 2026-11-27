import type { CSSProperties } from 'react';
import { SlotPicture } from '@/components/Picture';
import { photoUrl } from '@/lib/photo';
import { carPlace, slotScene, type SiteCutout } from '@/lib/slot-cars';
import type { SlotPhoto } from '@/lib/types';
import { FADE, STEP, heroKeyframes } from '@/features/home/hero-keyframes';

// R50 hotfix 2 (5080). The owner's spec: on the home pages, the heroes and anywhere a sample car is replaced by a real car,
// ONLY the cutout (the car alone, transparent), never the full photo with its background. A section that still has its
// built-in sample photo (the stand-in) shows its plate (the photo without the sample car) with real cars cut out where the
// sample car stood (lib/slot-cars.ts, 3080): the side profile of each studio set, keyed out by the site itself from the same
// render the listing shows (app.site_cutouts, made by the listing worker, 5080). The hero shows its cars in turn (6 seconds a
// car, a 1-second fade, pure CSS; reduced motion: the first car). No cutout yet, or a section photo an Admin replaced in Site
// content: the section photo as it is (the sample car stays). 3701's whole studio photos are gone from these sections.
export function SlotCars({ slot, photo, cutouts, rotate = false, eager = false, sizes = '100vw' }: {
  slot: string; photo: SlotPhoto | null; cutouts: readonly SiteCutout[]; rotate?: boolean; eager?: boolean; sizes?: string;
}) {
  const scene = slotScene(slot, photo, cutouts, { rotate });
  if (!scene) return <SlotPicture p={photo} eager={eager} sizes={sizes} />;
  const { wide, tall } = scene;
  const frame = { '--ww': wide.width, '--wh': wide.height, '--tw': tall.width, '--th': tall.height } as CSSProperties;
  return (
    <span className="slot-cars" data-testid="slot-cars" data-slot={scene.slot}>
      <span className="slot-cars__frame" style={frame}>
        <picture>
          <source media="(min-width: 48rem)" srcSet={wide.plate} width={wide.width} height={wide.height} />
          <img className="slot-cars__plate" src={tall.plate} width={tall.width} height={tall.height} alt={photo?.alt ?? ''} sizes={sizes}
            loading={eager ? 'eager' : 'lazy'} fetchPriority={eager ? 'high' : undefined} decoding="async" />
        </picture>
        {scene.cars.map((cars, i) => {
          const w = carPlace(wide.boxes[i]!), t = carPlace(tall.boxes[i] ?? wide.boxes[i]!);
          const pos = { '--wl': w.left, '--wcw': w.width, '--wb': w.bottom, '--tl': t.left, '--tcw': t.width, '--tb': t.bottom } as CSSProperties;
          const n = cars.length;
          return (
            <span key={i} className="slot-cars__pos" style={pos} aria-hidden="true" data-count={n}>
              {n > 1 && <style>{`${heroKeyframes(n)}.slot-cars__pos[data-count="${n}"] .slot-cars__turn{animation:hero-slides-${n} ${n * STEP}s linear infinite}`}</style>}
              {cars.map((c, k) => (
                <span key={c.path} className="slot-cars__turn" style={n > 1 ? { animationDelay: `${k === 0 ? -FADE : k * STEP - FADE}s` } : { opacity: 1 }}>
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img className={c.mirror ? 'slot-cars__car slot-cars__car--mirror' : 'slot-cars__car'} src={photoUrl(c.path)} width={c.width} height={c.height} alt=""
                    loading={eager && k === 0 ? 'eager' : 'lazy'} fetchPriority={eager && k === 0 ? 'high' : 'low'} decoding="async" data-testid="slot-car" />
                </span>))}
            </span>
          );
        })}
      </span>
    </span>
  );
}
