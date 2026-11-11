import type { ReactNode } from 'react';
import { DeckFrame } from './DeckFrame';
import { ABOUT, BUSINESS_LINES, COMPETITORS, COVER, DEMAND, DIFFERENCE, FOOTNOTES, MODEL, PER_CAR, PLATFORM, RAISE, SLIDES, dollars, monthlyInterest, perCarRevenue, type PitchSlide } from './pitch';

// The investor pitch deck, 2026 (release 35): the owner's ten slides as responsive HTML (no images of slides), in the
// deck frame (counter, previous and next, keyboard and swipe, Download PDF). Every word and number is in pitch.ts.

const NOTICE = `${FOOTNOTES.internal} ${FOOTNOTES.offer}.`;

function Logo() {
  return (<>
    {/* eslint-disable-next-line @next/next/no-img-element */}
    <img className="dk-logo dk-logo--light" src="/brand/carma-logo-black.svg" width={857} height={152} alt="" aria-hidden="true" />
    {/* eslint-disable-next-line @next/next/no-img-element */}
    <img className="dk-logo dk-logo--dark" src="/brand/carma-logo-white.svg" width={857} height={152} alt="" aria-hidden="true" />
    {/* eslint-disable-next-line @next/next/no-img-element */}
    <img className="dk-logo dk-logo--red" src="/brand/carma-logo-mono-white.svg" width={857} height={152} alt="" aria-hidden="true" />
  </>);
}

function Slide({ s, n, children }: { s: PitchSlide; n: number; children: ReactNode }) {
  return (
    <section className={`dk-slide${s.tone ? ` dk-slide--${s.tone}` : ''}`} id={s.id} aria-label={`Slide ${n}: ${s.title}`} tabIndex={-1} data-testid="deck-slide">
      <div className="dk-slide__in">
        {children}
        <footer className="dk-foot">
          <span className="dk-foot__brand" role="img" aria-label="CarmaCars"><Logo /></span>
          <span className="dk-foot__note">{NOTICE}</span>
          <span className="dk-foot__n" aria-hidden="true" />
        </footer>
      </div>
    </section>
  );
}

function Head({ s, lead }: { s: PitchSlide; lead?: ReactNode }) {
  return <header style={{ display: 'grid', gap: '0.5em' }}>
    <p className="dk-kicker">{s.kicker}</p>
    <h2 className="dk-title">{s.title}</h2>
    {lead && <p className="dk-lead">{lead}</p>}
  </header>;
}

export function PitchDeck({ multiplier = PER_CAR.multiplier }: { multiplier?: number }) {
  const [cover, model, lines, competitors, difference, platform, demand, perCar, ask, about] = SLIDES as [PitchSlide, PitchSlide, PitchSlide, PitchSlide, PitchSlide, PitchSlide, PitchSlide, PitchSlide, PitchSlide, PitchSlide];
  const mult = `${+multiplier.toFixed(2)}x`;
  return (
    <DeckFrame titles={SLIDES.map((s) => s.title)}>
      <Slide s={cover} n={1}>
        <div className="dk-body" style={{ alignContent: 'center', gap: '1.5em' }}>
          <p className="dk-kicker">{COVER.kicker}</p>
          <p className="dk-wordmark" role="img" aria-label="CarmaCars"><Logo /></p>
          <h2 className="dk-title dk-title--hero" style={{ maxWidth: '22em' }}>{COVER.title}</h2>
          <p className="dk-lead" data-testid="deck-tagline">{COVER.line}</p>
        </div>
      </Slide>

      <Slide s={model} n={2}>
        <Head s={model} />
        <div className="dk-body">
          <div className="dk-cols" style={{ ['--dk-cols' as string]: 3 }}>{MODEL.supply.map((x) => <div key={x} className="dk-card dk-card--accent"><h3>{x}</h3></div>)}</div>
          <p className="dk-lead">{MODEL.lead}</p>
          <ul className="dk-grid dk-chips" data-testid="deck-extras">{MODEL.extras.map((x) => <li key={x} className="dk-card"><h3>{x}</h3></li>)}</ul>
        </div>
      </Slide>

      <Slide s={lines} n={3}>
        <Head s={lines} />
        <div className="dk-body"><ol className="dk-grid" data-testid="deck-lines">
          {BUSINESS_LINES.map((x) => <li key={x.title} className="dk-card dk-card--accent"><h3>{x.title}</h3><p>{x.text}</p></li>)}
        </ol></div>
      </Slide>

      <Slide s={competitors} n={4}>
        <Head s={competitors} />
        <div className="dk-body"><div className="dk-cols" style={{ ['--dk-cols' as string]: 3 }}>
          {COMPETITORS.others.map((x) => <div key={x.title} className="dk-card"><h3>{x.title}</h3><p>{x.text}</p></div>)}
          <div className="dk-card dk-card--accent" data-testid="deck-us"><h3>CarmaCars</h3><ul className="dk-list">{COMPETITORS.carmacars.map((x) => <li key={x}>{x}</li>)}</ul></div>
        </div></div>
      </Slide>

      <Slide s={difference} n={5}>
        <Head s={difference} />
        <div className="dk-body"><div className="dk-grid">{DIFFERENCE.map((x) => <div key={x} className="dk-card dk-card--accent"><h3>{x}</h3></div>)}</div></div>
      </Slide>

      <Slide s={platform} n={6}>
        <Head s={platform} />
        <div className="dk-body">
          <div className="dk-cols" style={{ ['--dk-cols' as string]: 2 }} data-testid="deck-seo">
            {PLATFORM.search.map((x) => <div key={x.text} className="dk-card"><p className="dk-stat__big">{x.big}</p><p>{x.text}</p></div>)}
          </div>
          <ul className="dk-grid" data-testid="deck-ai">{PLATFORM.ai.map((x) => <li key={x} className="dk-card dk-card--accent"><p>{x}</p></li>)}</ul>
          <p className="dk-note">Google clicks and impressions, week by week, follow the slides.</p>
        </div>
      </Slide>

      <Slide s={demand} n={7}>
        <Head s={demand} />
        <div className="dk-body"><div className="dk-grid" data-testid="deck-demand">
          {DEMAND.map((x) => <div key={x.text} className="dk-card"><p className="dk-stat__big">{x.big}</p><p>{x.text}</p></div>)}
        </div></div>
      </Slide>

      <Slide s={perCar} n={8}>
        <Head s={perCar} />
        <div className="dk-body">
          <div className="dk-cols" style={{ ['--dk-cols' as string]: 3 }}>
            <div className="dk-card dk-card--accent"><p className="dk-stat__big" data-testid="deck-per-day">{dollars(PER_CAR.perRentedDay)}</p><p>average earned per rented day (October actual)</p></div>
            <div className="dk-card"><p className="dk-stat__big" data-testid="deck-per-car">{dollars(perCarRevenue())}</p><p>rental revenue per car in an example of {PER_CAR.exampleDays} rented days</p></div>
            <div className="dk-card"><p className="dk-stat__big" data-testid="deck-multiplier">{mult}</p><p>CarmaCars&apos; figure: a {mult} multiplier on the money we invest in the fleet</p></div>
          </div>
          <p className="dk-note">{FOOTNOTES.illustration} {FOOTNOTES.internal}</p>
        </div>
      </Slide>

      <Slide s={ask} n={9}>
        <Head s={ask} />
        <div className="dk-body"><div className="dk-cols" style={{ ['--dk-cols' as string]: 3 }}>
          <div className="dk-card" data-testid="deck-funds"><h3>Use of funds</h3><ul className="dk-list">{RAISE.funds.map((f) => <li key={f.label}><b>{dollars(f.amount)}</b> {f.label.toLowerCase()}</li>)}</ul></div>
          <div className="dk-card" data-testid="deck-option-1"><h3>Option 1: {RAISE.option1.lowPct} to {RAISE.option1.highPct}% a year</h3>
            <p>Paid monthly, simple interest: {dollars(monthlyInterest(RAISE.amount, RAISE.option1.lowPct))} to {dollars(monthlyInterest(RAISE.amount, RAISE.option1.highPct))} a month on {dollars(RAISE.amount)}.</p></div>
          <div className="dk-card" data-testid="deck-option-2"><h3>Option 2: {RAISE.option2.lowPct} to {RAISE.option2.highPct}% profit share</h3>
            <p>From the cars this money puts on the road.</p></div>
        </div><p className="dk-note">{FOOTNOTES.offer}.</p></div>
      </Slide>

      <Slide s={about} n={10}>
        <Head s={about} lead={ABOUT.text} />
        <div className="dk-body"><div className="dk-cols" style={{ ['--dk-cols' as string]: 2 }}>
          {ABOUT.people.map((p) => <div key={p.name} className="dk-card"><h3>{p.name}</h3><p>{p.role}</p></div>)}
        </div></div>
      </Slide>
    </DeckFrame>
  );
}
