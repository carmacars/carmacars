import Link from 'next/link';
import type { ReactNode } from 'react';
import { PortalIcon } from './icons';
const cx = (...c: Array<string | false | null | undefined>) => c.filter(Boolean).join(' ');

export interface MoneyPart { key: string; label: ReactNode; amount: ReactNode; state: 'paid' | 'owing' | 'held' | 'refunded' | 'info'; note?: ReactNode; href?: string; cta?: string; testId?: string }
const STATE_WORD: Record<MoneyPart['state'], string> = { paid: 'Paid', owing: 'To pay', held: 'Held', refunded: 'Refunded', info: '' };
/** What is paid and what is owing (the renter's booking; MoneySummary is the plain rows-and-total list), by part, with one Pay button per open part and the receipts under it. */
export function MoneyCard({ title = 'Money', paid, owing, parts, pay, children, testId }: {
  title?: string; paid: ReactNode; owing: ReactNode | null; parts: MoneyPart[]; pay?: { href: string; label: string; testId?: string } | null; children?: ReactNode; testId?: string;
}) {
  return (
    <section className="pu-panel pu-mc" aria-labelledby="pu-mc-h" data-testid={testId}>
      <h2 className="pu-title" id="pu-mc-h">{title}</h2>
      <div className="pu-mc__totals">
        <div className="pu-mc__total"><span className="pu-mc__label">Paid</span><span className="pu-mc__num" data-testid="money-paid">{paid}</span></div>
        <div className={cx('pu-mc__total', owing ? 'is-owing' : undefined)}><span className="pu-mc__label">Owing</span><span className="pu-mc__num" data-testid="money-owing">{owing ?? 'Nothing'}</span></div>
      </div>
      {pay && <Link prefetch={false} className="btn btn--primary btn--block" href={pay.href} data-testid={pay.testId ?? 'money-pay'}><PortalIcon name="card" size={18} />{pay.label}</Link>}
      {parts.length > 0 && (
        <ul className="pu-mc__parts">{parts.map((p) => (
          <li key={p.key} className={cx('pu-mc__part', `is-${p.state}`)} data-testid={p.testId}>
            <span className="pu-mc__part-text"><span>{p.label}</span>{(p.note || STATE_WORD[p.state]) && <span className="pu-mc__part-note">{STATE_WORD[p.state] && <b className="pu-mc__state">{STATE_WORD[p.state]}</b>}{p.note}</span>}</span>
            <span className="pu-mc__part-amt">{p.amount}{p.href && p.cta && <Link prefetch={false} className="link small" href={p.href}>{p.cta}</Link>}</span>
          </li>))}
        </ul>
      )}
      {children}
    </section>
  );
}

