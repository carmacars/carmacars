import Link from '@/components/Link';
import { Ico, type KitIcon } from './icons';
import '@/styles/seo-kit.css';

// The search page kit (release 48, docs/changes/2026-11-20-r48-seo.md): the blocks every product, service and search
// page is built from, so a long page reads fast: a hero with one action, jump chips, sections with a heading and one
// line, icon tiles, price cards, a comparison table, steps, trust badges, facts an answer engine can quote, folds for the
// long detail, and the phone's sticky action. Server-rendered, no client code. Styles: src/styles/seo-kit.css.

export function KitHero({ kicker, icon, h1, lead, pill, children, note, cta }: { kicker?: string; icon?: KitIcon; h1: string; lead: string; pill?: string; children?: React.ReactNode; note?: string; cta?: React.ReactNode }) {
  return (
    <section className="sk sk-hero on-dark" data-testid="kit-hero">
      <div className="wrap">
        {children}
        {kicker && <p className="sk-hero__kicker">{icon && <Ico name={icon} />}{kicker}</p>}
        <h1 className="d1">{h1}</h1>
        {pill && <p style={{ marginTop: 'var(--s-3)' }}><span className="sk-pill sk-pill--soon" data-testid="kit-pill">{pill}</span></p>}
        <p className="sk-hero__lead" data-testid="kit-lead">{lead}</p>
        {cta}
        {note && <p className="sk-hero__note">{note}</p>}
      </div>
    </section>
  );
}
export function KitCta({ primary, secondary }: { primary: [string, string]; secondary?: [string, string] }) {
  return (
    <p className="sk-hero__cta">
      <Link prefetch={false} className="btn btn--primary btn--lg" href={primary[1]} data-testid="kit-cta">{primary[0]}</Link>
      {secondary && <Link prefetch={false} className="btn btn--ghost btn--lg" href={secondary[1]}>{secondary[0]}</Link>}
    </p>
  );
}

/** "On this page": the chips that jump to each section. */
export function KitToc({ items }: { items: Array<[string, string]> }) {
  if (items.length < 3) return null;
  return <nav className="sk sk-toc" aria-label="On this page"><div className="wrap"><div className="sk-toc__track">{items.map(([label, id]) => <a key={id} href={`#${id}`}>{label}</a>)}</div></div></nav>;
}

export function KitSection({ id, kicker, h, p, children }: { id: string; kicker?: string; h: string; p?: string; children: React.ReactNode }) {
  return (
    <section className="sk sk-sec" id={id} aria-labelledby={`h-${id}`} data-kit-section={id}>
      <div className="sk-sec__head">
        {kicker && <p className="sk-sec__kicker">{kicker}</p>}
        <h2 className="d2" id={`h-${id}`}>{h}</h2>
        {p && <p>{p}</p>}
      </div>
      {children}
    </section>
  );
}

export interface Tile { icon: KitIcon; title: string; text: string }
export function KitTiles({ items, four }: { items: Tile[]; four?: boolean }) {
  return <ul className={`sk-tiles${four ? ' sk-tiles--4' : ''}`} data-testid="kit-tiles">{items.map((t) => <li key={t.title} className="sk-tile"><span className="sk-tile__ico"><Ico name={t.icon} /></span><div><h3>{t.title}</h3><p>{t.text}</p></div></li>)}</ul>;
}

export interface PriceCard { tag?: string; forWhom: string; amount: string; per?: string; points: string[]; best?: boolean }
export function KitPrices({ cards, fine }: { cards: PriceCard[]; fine?: string }) {
  return (
    <>
      <ul className={`sk-prices${cards.length === 2 ? ' sk-prices--2' : ''}`} data-testid="kit-prices">
        {cards.map((c) => (
          <li key={c.forWhom} className={`sk-price${c.best ? ' sk-price--best' : ''}`}>
            {c.tag && <span className="sk-price__tag">{c.tag}</span>}
            <span className="sk-price__for">{c.forWhom}</span>
            <span className="sk-price__amt num">{c.amount}{c.per && <small>{c.per}</small>}</span>
            {c.points.length > 0 && <ul>{c.points.map((x) => <li key={x}><Ico name="check" /><span>{x}</span></li>)}</ul>}
          </li>))}
      </ul>
      {fine && <p className="sk-fine">{fine}</p>}
    </>
  );
}

/** A comparison table; `us` is the column (from 1) that is ours. Scrolls sideways on a phone. */
export function KitCompare({ caption, head, rows, us = 1 }: { caption: string; head: string[]; rows: string[][]; us?: number }) {
  return (
    <div className="table-scroll" tabIndex={0} role="region" aria-label={caption} data-testid="kit-compare">
      <table className="sk-compare">
        <caption className="vh">{caption}</caption>
        <thead><tr>{head.map((h, i) => <th key={h} scope="col" className={i === us ? 'is-us' : undefined}>{h}</th>)}</tr></thead>
        <tbody>{rows.map((r) => <tr key={r[0]}>{r.map((c, i) => (i === 0 ? <th key={i} scope="row">{c}</th> : <td key={i} className={i === us ? 'is-us' : undefined}>{c}</td>))}</tr>)}</tbody>
      </table>
    </div>
  );
}

export function KitSteps({ steps }: { steps: Array<[string, string]> }) {
  return <ol className="sk-steps" style={{ ['--sk-steps' as string]: Math.min(steps.length, 4) }} data-testid="kit-steps">{steps.map(([h, p]) => <li key={h}><div><h3>{h}</h3><p>{p}</p></div></li>)}</ol>;
}

export function KitTrust({ items, band }: { items: Array<[KitIcon, string]>; band?: boolean }) {
  return <ul className={`sk-trust${band ? ' sk-trust--band' : ''}`} data-testid="kit-trust">{items.map(([icon, text]) => <li key={text}><Ico name={icon} /><span>{text}</span></li>)}</ul>;
}

/** Facts in label and value pairs, the form answer engines quote. A fact without a value is left out. */
export function KitFacts({ rows }: { rows: Array<[string, string | null | undefined]> }) {
  const r = rows.filter((x): x is [string, string] => Boolean(x[1]));
  if (!r.length) return null;
  return <dl className="sk-facts" data-testid="kit-facts">{r.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}</dl>;
}

/** A fold: the heading stays, the detail opens on a tap. The text is in the page either way (search engines read it). */
export function KitFold({ id, h, open, children, level = 2, attrs }: { id: string; h: string; open?: boolean; children: React.ReactNode; level?: 2 | 3; attrs?: Record<string, string> }) {
  const H = level === 2 ? 'h2' : 'h3';
  return <details className="sk-fold" open={open} {...attrs}><summary><H id={id}>{h}</H></summary><div className="sk-fold__body">{children}</div></details>;
}

/** The phone's sticky action at the bottom of a search page (hidden on wide screens and in the store app). */
export function KitSticky({ title, sub, cta, href }: { title: string; sub?: string; cta: string; href: string }) {
  return (
    <div className="sk sk-sticky" data-testid="kit-sticky">
      <span className="sk-sticky__text"><b>{title}</b>{sub && <span>{sub}</span>}</span>
      <Link prefetch={false} className="btn btn--primary" href={href}>{cta}</Link>
    </div>
  );
}
