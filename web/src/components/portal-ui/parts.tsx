import Link from 'next/link';
import type { ReactNode } from 'react';
import { CarImage } from '@/components/Picture';
import type { Photo } from '@/lib/types';
import { PortalIcon, type PortalIconName } from './icons';

// The portals' shared building blocks (portal-ui, October 24, 2026; docs/changes/2026-10-24-renter-portal-design.md).
// Server components, CSS in ./portal-ui.css under the .pu scope, design tokens as --pu-* custom properties. The renter
// portal uses them first; the owner and investor portals reuse them. Rules: phone first (390 px), no library, motion only
// under prefers-reduced-motion: no-preference, colour never the only signal, every control 44 px and focus visible.

type Tone = 'neutral' | 'brand' | 'dark' | 'ok' | 'warn';
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

/** The large photo card at the top of a portal page: the photo, a glass panel with the title over it, then a body. */
export function PortalHero({ photo, alt, eager = true, kicker, title, titleAs = 'h1', subtitle, chips, aside, children, testId, className }: {
  photo: Photo | null; alt: string; eager?: boolean; kicker?: ReactNode; title: ReactNode; titleAs?: 'h1' | 'h2'; subtitle?: ReactNode;
  chips?: ReactNode; aside?: ReactNode; children?: ReactNode; testId?: string; className?: string;
}) {
  const H = titleAs;
  return (
    <section className={cx('pu-hero', className)} data-testid={testId} aria-label={typeof title === 'string' ? title : undefined}>
      <div className="pu-hero__media">
        <CarPhoto photo={photo} alt={alt} eager={eager} sizes="(min-width: 64rem) 66vw, 100vw" />
        <div className="pu-hero__scrim" aria-hidden="true" />
        <div className="pu-hero__glass">
          {(chips || kicker) && <div className="pu-hero__chips">{chips}{kicker && <span className="pu-hero__kicker">{kicker}</span>}</div>}
          <H className="pu-hero__title">{title}</H>
          {subtitle && <p className="pu-hero__sub">{subtitle}</p>}
        </div>
      </div>
      {(children || aside) && (
        <div className={cx('pu-hero__body', aside ? 'pu-hero__body--split' : undefined)}>
          {children && <div className="pu-hero__main">{children}</div>}
          {aside && <div className="pu-hero__aside">{aside}</div>}
        </div>
      )}
    </section>
  );
}

/** One key number: an icon, a label, the value, and a line under it. */
export function StatCard({ icon, label, value, sub, tone = 'neutral', href, testId }: { icon?: PortalIconName; label: ReactNode; value: ReactNode; sub?: ReactNode; tone?: Tone; href?: string; testId?: string }) {
  const body = (
    <>
      <span className="pu-stat__label">{icon && <PortalIcon name={icon} size={16} />}{label}</span>
      <span className="pu-stat__value">{value}</span>
      {sub && <span className="pu-stat__sub">{sub}</span>}
    </>
  );
  if (href) {
    const ext = /^(https?:|tel:|mailto:)/.test(href);
    return ext ? <a className={cx('pu-stat pu-stat--link', `pu-tone-${tone}`)} href={href} data-testid={testId} {...(href.startsWith('http') ? { target: '_blank', rel: 'noopener noreferrer' } : {})}>{body}</a>
      : <Link prefetch={false} className={cx('pu-stat pu-stat--link', `pu-tone-${tone}`)} href={href} data-testid={testId}>{body}</Link>;
  }
  return <div className={cx('pu-stat', `pu-tone-${tone}`)} data-testid={testId}>{body}</div>;
}
export function StatGrid({ children, cols, label }: { children: ReactNode; cols?: 2 | 3 | 4; label?: string }) {
  return <div className={cx('pu-stats', cols && `pu-stats--${cols}`)} role={label ? 'group' : undefined} aria-label={label}>{children}</div>;
}

/** A ring showing how far along something is (value of total); the number in the middle, the words beside it. */
export function ProgressRing({ value, total, label, size = 88, testId }: { value: number; total: number; label: ReactNode; size?: number; testId?: string }) {
  const r = 42, c = 2 * Math.PI * r;
  const share = total > 0 ? Math.min(1, Math.max(0, value / total)) : 0;
  return (
    <div className="pu-ring" data-testid={testId} style={{ ['--pu-ring-size' as string]: `${size}px` }}>
      <svg viewBox="0 0 100 100" role="img" aria-label={`${value} of ${total} done`}>
        <circle className="pu-ring__track" cx="50" cy="50" r={r} />
        <circle className="pu-ring__bar" cx="50" cy="50" r={r} strokeDasharray={c} strokeDashoffset={c * (1 - share)} style={{ ['--pu-ring-c' as string]: c }} />
      </svg>
      <span className="pu-ring__num" aria-hidden="true">{value}<small>/{total}</small></span>
      <span className="pu-ring__label">{label}</span>
    </div>
  );
}

/** One action: an icon, what it does and a line under it. A link (page, phone, anchor) or, with `as`, any element. */
export function ActionTile({ href, icon, title, note, tone = 'neutral', testId, children }: { href?: string; icon: PortalIconName; title: ReactNode; note?: ReactNode; tone?: Tone; testId?: string; children?: ReactNode }) {
  const inner = (
    <>
      <span className="pu-tile__icon"><PortalIcon name={icon} size={20} /></span>
      <span className="pu-tile__text"><span className="pu-tile__title">{title}</span>{note && <span className="pu-tile__note">{note}</span>}</span>
      <span className="pu-tile__go" aria-hidden="true"><PortalIcon name="arrow" size={16} /></span>
    </>
  );
  const cls = cx('pu-tile', `pu-tone-${tone}`);
  if (children) return <div className={cls} data-testid={testId}>{inner}<span className="pu-tile__slot">{children}</span></div>;
  if (!href) return null;
  if (/^(tel:|mailto:|https?:)/.test(href)) return <a className={cls} href={href} data-testid={testId}>{inner}</a>;
  return <Link prefetch={false} className={cls} href={href} data-testid={testId}>{inner}</Link>;
}
export function ActionGrid({ children, label }: { children: ReactNode; label?: string }) {
  return <div className="pu-tiles" role={label ? 'group' : undefined} aria-label={label}>{children}</div>;
}

/** A list of stages: done, the current one, and what is still to come. */
export function Timeline({ children, label }: { children: ReactNode; label?: string }) {
  return <ol className="pu-timeline" aria-label={label}>{children}</ol>;
}
export function TimelineItem({ state, title, note, href }: { state: 'done' | 'current' | 'todo'; title: ReactNode; note?: ReactNode; href?: string }) {
  return (
    <li className={cx('pu-tl', `pu-tl--${state}`)} aria-current={state === 'current' ? 'step' : undefined}>
      <span className="pu-tl__dot" aria-hidden="true">{state === 'done' && <PortalIcon name="check" size={12} />}</span>
      <span className="pu-tl__text">
        {href && state !== 'done' ? <Link prefetch={false} className="pu-tl__title link" href={href}>{title}</Link> : <span className="pu-tl__title">{title}</span>}
        <span className="vh">{state === 'done' ? ', done' : state === 'current' ? ', next' : ', to do'}</span>
        {note && <span className="pu-tl__note">{note}</span>}
      </span>
    </li>
  );
}

export interface MoneyPart { key: string; label: ReactNode; amount: ReactNode; state: 'paid' | 'owing' | 'held' | 'refunded' | 'info'; note?: ReactNode; href?: string; cta?: string; testId?: string }
const STATE_WORD: Record<MoneyPart['state'], string> = { paid: 'Paid', owing: 'To pay', held: 'Held', refunded: 'Refunded', info: '' };
/** What is paid and what is owing, by part, with one Pay button per open part and the receipts under it. */
export function MoneySummary({ title = 'Money', paid, owing, parts, pay, children, testId }: {
  title?: string; paid: ReactNode; owing: ReactNode | null; parts: MoneyPart[]; pay?: { href: string; label: string; testId?: string } | null; children?: ReactNode; testId?: string;
}) {
  return (
    <section className="pu-card pu-money" aria-labelledby="pu-money-h" data-testid={testId}>
      <h2 className="pu-card__title" id="pu-money-h">{title}</h2>
      <div className="pu-money__totals">
        <div className="pu-money__total"><span className="pu-money__label">Paid</span><span className="pu-money__num" data-testid="money-paid">{paid}</span></div>
        <div className={cx('pu-money__total', owing ? 'is-owing' : undefined)}><span className="pu-money__label">Owing</span><span className="pu-money__num" data-testid="money-owing">{owing ?? 'Nothing'}</span></div>
      </div>
      {pay && <Link prefetch={false} className="btn btn--primary btn--block" href={pay.href} data-testid={pay.testId ?? 'money-pay'}><PortalIcon name="card" size={18} />{pay.label}</Link>}
      {parts.length > 0 && (
        <ul className="pu-money__parts">{parts.map((p) => (
          <li key={p.key} className={cx('pu-money__part', `is-${p.state}`)} data-testid={p.testId}>
            <span className="pu-money__part-text"><span>{p.label}</span>{(p.note || STATE_WORD[p.state]) && <span className="pu-money__part-note">{STATE_WORD[p.state] && <b className="pu-money__state">{STATE_WORD[p.state]}</b>}{p.note}</span>}</span>
            <span className="pu-money__part-amt">{p.amount}{p.href && p.cta && <Link prefetch={false} className="link small" href={p.href}>{p.cta}</Link>}</span>
          </li>))}
        </ul>
      )}
      {children}
    </section>
  );
}

const DOC_ICON: Record<string, PortalIconName> = { receipt: 'receipt', renter_statement: 'receipt', statement: 'receipt', condition_report: 'camera', id_front: 'id', id_back: 'id', face: 'id', coverage_proof: 'shield' };
/** One document: an icon for its kind, the title, when, and the link to open or download it. */
export function DocumentRow({ kind, title, meta, href, action = 'Download', testId }: { kind: string; title: ReactNode; meta?: ReactNode; href: string; action?: string; testId?: string }) {
  return (
    <li className="pu-doc">
      <span className="pu-doc__icon"><PortalIcon name={DOC_ICON[kind] ?? 'doc'} size={18} /></span>
      <span className="pu-doc__text"><span className="pu-doc__title">{title}</span>{meta && <span className="pu-doc__meta">{meta}</span>}</span>
      {href.startsWith('/') && !href.startsWith('/files/') && !href.startsWith('/account/documents/')
        ? <Link prefetch={false} className="pu-doc__go" href={href} data-testid={testId}>{action}</Link>
        : <a className="pu-doc__go" href={href} data-testid={testId}>{action}<PortalIcon name="download" size={16} /></a>}
    </li>
  );
}
export function DocumentList({ children, testId }: { children: ReactNode; testId?: string }) {
  return <ul className="pu-docs" data-testid={testId}>{children}</ul>;
}

/** A white card with a title row (and an optional link or action at its right). */
export function PortalCard({ id, title, action, children, tone, testId, className }: { id: string; title: ReactNode; action?: ReactNode; children: ReactNode; tone?: 'next'; testId?: string; className?: string }) {
  return (
    <section className={cx('pu-card', tone === 'next' && 'pu-card--next', className)} id={id} aria-labelledby={`${id}-h`} data-testid={testId}>
      <div className="pu-card__head"><h2 className="pu-card__title" id={`${id}-h`}>{title}</h2>{action}</div>
      {children}
    </section>
  );
}

/** Details most visits skip, opened smoothly where the browser can animate it. */
export function Disclosure({ summary, children, open = false, testId }: { summary: ReactNode; children: ReactNode; open?: boolean; testId?: string }) {
  return <details className="pu-disclosure" open={open} data-testid={testId}><summary>{summary}<PortalIcon name="arrow" size={16} className="pu-disclosure__chev" /></summary><div className="pu-disclosure__body">{children}</div></details>;
}

/** Nothing here yet: an icon, a line, what to do, and one button. */
export function EmptyState({ icon = 'car', title, children, action, testId }: { icon?: PortalIconName; title: ReactNode; children?: ReactNode; action?: ReactNode; testId?: string }) {
  return (
    <div className="pu-empty" data-testid={testId}>
      <span className="pu-empty__icon"><PortalIcon name={icon} size={28} /></span>
      <p className="pu-empty__title">{title}</p>
      {children && <div className="pu-empty__text">{children}</div>}
      {action}
    </div>
  );
}

/** Loading placeholders in the shape of the hero and the cards (screen readers hear "Loading"). */
export function HeroSkeleton() {
  return (
    <div className="pu-sk" role="status">
      <span className="vh">Loading</span>
      <div className="pu-sk__hero skeleton" aria-hidden="true" />
      <div className="pu-stats" aria-hidden="true">{[0, 1, 2, 3].map((i) => <div key={i} className="pu-sk__stat skeleton" />)}</div>
      <div className="pu-sk__card skeleton" aria-hidden="true" />
    </div>
  );
}
