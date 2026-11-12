import type { ReactNode } from 'react';
import Link from '@/components/Link';
import { LiveCountdown } from '@/components/portal-ui/live';
import { NowPanel, type NowFact } from '@/features/portal-nav/NowPanel';
import type { NextAction } from './next-action';
import './still-needed.css';

// r40 "Do this next": the one card at the top of /account and of each booking, on the portals' shared Now panel (the
// same black band as the Admin, staff, owner and field homes). One sentence, the one red button, the time left when
// there is a deadline (red when it is close or passed), and on a phone the same button kept in view at the bottom of
// the screen while there is something to do (the r38 still-needed bar, .sn__next).
export function NextActionPanel({ a, testId, titleId, primaryTestId, dropTrip, extra, children }: {
  a: NextAction; testId: string; titleId: string; primaryTestId?: string; dropTrip?: boolean; extra?: ReactNode; children?: ReactNode;
}) {
  const actions = a.actions.filter((x) => !(dropTrip && x.key === 'trip')).map((x) => (x.primary && primaryTestId && x.key === 'step' ? { ...x, testId: primaryTestId } : x));
  const d = a.deadline;
  const facts: NowFact[] = [];
  if (d) {
    facts.push({ key: 'deadline', label: d.late ? `${d.label} overdue by` : `${d.label} in`, warn: d.late || d.soon, testId: `${testId}-deadline`,
      value: <LiveCountdown until={d.at} before="" after="{t}" initial={d.span} /> });
  }
  const primary = actions.find((x) => x.primary);
  return (
    <>
      <NowPanel testId={testId} titleId={titleId} kicker={a.kicker} headline={a.headline} detail={a.detail} urgent={a.urgent} actions={actions} facts={facts} extra={extra}>
        {children}
      </NowPanel>
      {a.urgent && primary && !/^(tel:|mailto:|https?:)/.test(primary.href) && (
        <div className="sn__next" data-testid={`${testId}-sticky`}><Link prefetch={false} className="btn btn--primary btn--sm" href={primary.href}>Next: {primary.label}</Link></div>
      )}
    </>
  );
}
