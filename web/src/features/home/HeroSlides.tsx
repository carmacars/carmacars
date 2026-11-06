import { SlotPicture } from '@/components/Picture';
import { photoUrl } from '@/lib/photo';
import type { SlotPhoto } from '@/lib/types';
import { FADE, STEP, heroKeyframes } from './hero-keyframes';

// The home page's hero photo (release 28, B5; migration 0563): real cars of the fleet on the sample cars' black studio,
// one after another (6 seconds each, a 1-second cross-fade), in pure CSS. The sample car photo of Admin > Site content
// stays underneath: shown alone when no car has a studio photo, and it shows through if a car's photo does not load (the
// slides have empty alt text, so a broken image draws nothing). The slides fill the same box as before: no layout shift.
// The page is rebuilt hourly (an edge copy), so the list is read then, never per visit. Reduced motion: the first car only.
export interface HeroCar { path: string; width: number; height: number; alt: string | null; name: string; href: string }
export function HeroSlides({ sample, cars }: { sample: SlotPhoto | null; cars: HeroCar[] }) {
  const n = cars.length;
  return (
    <>
      <SlotPicture p={sample} eager={n === 0} />
      {n > 0 && (
        <div className="hero__slides" aria-hidden="true" data-testid="hero-slides" data-count={n}>
          {n > 1 && <style>{`${heroKeyframes(n)}.hero__media .hero__slide{animation:hero-slides-${n} ${n * STEP}s linear infinite}`}</style>}
          {cars.map((c, i) => (
            // eslint-disable-next-line @next/next/no-img-element
            <img key={c.path} className="hero__slide" src={photoUrl(c.path)} width={c.width} height={c.height} alt=""
              loading={i === 0 ? 'eager' : 'lazy'} fetchPriority={i === 0 ? 'high' : 'low'} decoding="async"
              style={n > 1 ? { animationDelay: `${i === 0 ? -FADE : i * STEP - FADE}s` } : { opacity: 1 }} />))}
        </div>)}
    </>
  );
}
