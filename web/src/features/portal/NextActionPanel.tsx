import type { ReactNode } from 'react';
import Link from '@/components/Link';
import { LiveCountdown } from '@/components/portal-ui/live';
import { NowPanel, type NowFact } from '@/features/portal-nav/NowPanel';
import { splitActions, type NextAction } from './next-action';
import { StickyNext } from './StickyNext';

// r40 "Do this next": the one card at the top of /account and of each booking, on the portals' shared Now panel (the
// same black band as the Admin, staff, owner and field homes). One sentence, the one red button and at most two others
// (the rest behind More), the time left when there is a deadline (red when it is close or passed), and on a phone the
// same red button kept at the bottom of the screen once the card has scrolled away (StickyNext).
const ext = (h: string) => /^(tel:|mailto:|https?:)/.test(h);

export function NextActionPanel({ a, testId, titleId, primaryTestId, dropTrip, extra, children }: {
  a: NextAction; testId: string; titleId: string; primaryTestId?: string; dropTrip?: boolean; extra?: ReactNode; children?: ReactNode;
}) {
  const actions = a.actions.filter((x) => !(dropTrip && x.key === 'trip')).map((x) => (x.primary && primaryTestId && x.key === 'step' ? { ...x, testId: primaryTestId } : x));
  const { shown, more } = splitActions(actions);
  const d = a.deadline;
  const facts: NowFact[] = [];
  if (d) {
    facts.push({ key: 'deadline', label: d.late ? `${d.label} overdue by` : `${d.label} in`, warn: d.late || d.soon, testId: `${testId}-deadline`,
      value: <LiveCountdown until={d.at} before="" after="{t}" initial={d.span} /> });
  }
  const primary = shown.find((x) => x.primary);
  const moreBox = more.length || extra ? (
    <details className="now__more" data-testid={`${testId}-more`}>
      <summary className="btn now__btn">More</summary>
      <div className="now__more-body">
        {more.map((x) => ext(x.href)
          ? <a key={x.key} className="btn now__btn" href={x.href} data-testid={x.testId}>{x.label}</a>
          : <Link prefetch={false} key={x.key} className="btn now__btn" href={x.href} data-testid={x.testId}>{x.label}</Link>)}
        {extra}
      </div>
    </details>
  ) : null;
  return (
    <>
      <NowPanel testId={testId} titleId={titleId} kicker={a.kicker} headline={a.headline} detail={a.detail} urgent={a.urgent} actions={shown} facts={facts} extra={moreBox}>
        {children}
      </NowPanel>
      {a.urgent && primary && !ext(primary.href) && <StickyNext watch={testId} href={primary.href} label={primary.label} testId={`${testId}-sticky`} />}
    </>
  );
}
