import type { CSSProperties } from 'react';
import { SlotPicture } from '@/components/Picture';
import { photoUrl } from '@/lib/photo';
import { carPlace, type SlotScene } from '@/lib/slot-cars';
import type { SlotPhoto } from '@/lib/types';
import { FADE, STEP, heroKeyframes } from '@/features/home/hero-keyframes';

// Release 48 O (3080): a section photo with real fleet cars cut out where its sample car stood (lib/slot-cars.ts). One
// frame cropped like the photo it replaces (object-fit: cover at the section's own focus, --px and --py in the CSS), the
// plate (the photo without its sample car) as a <picture> for the wide and the tall form, and the cars at the sample car's
// place in percent of the frame, so they keep their place at every width. The hero shows its cars in turn (6 seconds a car,
// a 1-second fade, pure CSS; reduced motion: the first car). The section's black gradient (its ::after) is drawn over the
// cars, behind the text. No scene: the section photo as before.
export function SlotCars({ scene, photo, eager = false, sizes = '100vw' }: { scene: SlotScene | null; photo: SlotPhoto | null; eager?: boolean; sizes?: string }) {
  if (!scene) return <SlotPicture p={photo} eager={eager} sizes={sizes} />;
  const { wide, tall } = scene;
  const frame = { '--ww': wide.width, '--wh': wide.height, '--tw': tall.width, '--th': tall.height } as CSSProperties;
  return (
    <span className="slot-cars" data-testid="slot-cars" data-slot={scene.slot}>
      <span className="slot-cars__frame" style={frame}>
        <picture>
          <source media="(min-width: 48rem)" srcSet={wide.plate} width={wide.width} height={wide.height} />
          {/* eslint-disable-next-line @next/next/no-img-element */}
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
