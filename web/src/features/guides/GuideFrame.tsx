import '@/styles/guide.css';
import { cookies } from 'next/headers';
import { GUIDE_NAME, GUIDE_PATH, guideBanner, type GuidePortal } from '@/server/guides';
import { GuideBannerClient } from './GuideClient';
import { SEEN_COOKIE } from './constants';

// The portal frame's two guide pieces (migration 0044): the "Guide" link at the top of every portal, and the
// first-visit banner. The banner asks the database once per device: after it is dismissed, or the guide is opened, a
// cookie on the device says so and the frame stops asking.

export function GuideLink({ portal, className = 'btn btn--quiet btn--sm gd-link' }: { portal: GuidePortal; className?: string }) {
  return (
    <a className={className} href={GUIDE_PATH[portal]} data-testid="guide-link">
      <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5z" /><path d="M4 20.5A2.5 2.5 0 0 1 6.5 18H20v3H6.5A2.5 2.5 0 0 1 4 20.5z" /></svg>
      Guide
    </a>
  );
}

export async function GuideBanner({ portal, userId }: { portal: GuidePortal; userId: string }) {
  let seen = false;
  try { seen = ((await cookies()).get(SEEN_COOKIE)?.value ?? '').split('.').includes(portal); } catch { seen = false; }
  if (seen) return null;
  const show = await guideBanner(userId, portal);
  // not shown: seen elsewhere, or the guide is not published yet (then the banner comes once it is)
  if (!show) return null;
  return <GuideBannerClient portal={portal} href={GUIDE_PATH[portal]} name={GUIDE_NAME[portal]} />;
}
