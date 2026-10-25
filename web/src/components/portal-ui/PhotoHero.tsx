// The photo hero of portal-ui: a car's photo with a glass panel over it, then a body (the renter's trip, October 24, 2026).
import type { ReactNode } from 'react';
import { CarImage } from '@/components/Picture';
import type { Photo } from '@/lib/types';
const cx = (...c: Array<string | false | null | undefined>) => c.filter(Boolean).join(' ');

/** A car's photo, or a clean branded placeholder when there is none (never a broken image). */
export function CarPhoto({ photo, alt, eager = false, sizes = '100vw', className }: { photo: Photo | null; alt: string; eager?: boolean; sizes?: string; className?: string }) {
  if (photo) return <div className={cx('pu-photo', className)}><CarImage p={photo} alt={alt} eager={eager} sizes={sizes} /></div>;
  return (
    <div className={cx('pu-photo pu-photo--empty', className)} role="img" aria-label={alt}>
      <svg viewBox="0 0 320 120" aria-hidden="true" focusable="false">
        <path d="M30 86h260M52 86c0-14 10-22 24-24l38-6 28-20c6-4 12-6 20-6h46c10 0 18 4 24 10l20 18 28 4c12 2 20 10 20 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" />
        <circle cx="96" cy="88" r="13" fill="none" stroke="currentColor" strokeWidth="2.2" /><circle cx="236" cy="88" r="13" fill="none" stroke="currentColor" strokeWidth="2.2" />
        <path d="M150 56h86" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
      </svg>
    </div>
  );
}

/** The large photo card at the top of a trip page (the renter's hero; the dark PortalHero is the owner and investor home): the photo, a glass panel with the title over it, then a body. */
export function PhotoHero({ photo, media, alt, eager = true, kicker, title, titleAs = 'h1', subtitle, chips, aside, children, testId, className }: {
  photo: Photo | null; /** another image in place of the photo (a licensed stock photo with its credit) */ media?: ReactNode; alt: string; eager?: boolean; kicker?: ReactNode; title: ReactNode; titleAs?: 'h1' | 'h2'; subtitle?: ReactNode;
  chips?: ReactNode; aside?: ReactNode; children?: ReactNode; testId?: string; className?: string;
}) {
  const H = titleAs;
  return (
    <section className={cx('pu-ph', className)} data-testid={testId} aria-label={typeof title === 'string' ? title : undefined}>
      <div className="pu-ph__media">
        {media ? <div className="pu-photo pu-photo--media">{media}</div> : <CarPhoto photo={photo} alt={alt} eager={eager} sizes="(min-width: 64rem) 66vw, 100vw" />}
        <div className="pu-ph__scrim" aria-hidden="true" />
        <div className="pu-ph__glass">
          {(chips || kicker) && <div className="pu-ph__chips">{chips}{kicker && <span className="pu-ph__kicker">{kicker}</span>}</div>}
          <H className="pu-ph__title">{title}</H>
          {subtitle && <p className="pu-ph__sub">{subtitle}</p>}
        </div>
      </div>
      {(children || aside) && (
        <div className={cx('pu-ph__body', aside ? 'pu-ph__body--split' : undefined)}>
          {children && <div className="pu-ph__main">{children}</div>}
          {aside && <div className="pu-ph__aside">{aside}</div>}
        </div>
      )}
    </section>
  );
}

