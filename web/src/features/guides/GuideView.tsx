import '@/styles/guide.css';
import { getSettings } from '@/lib/site';
import type { GuideData, GuidePortal } from '@/server/guides';
import { GuideTools, GuideSeen } from './GuideClient';

const fmtDay = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(iso));

// One guide as a page inside its portal: the contents (a sidebar on a wide screen, a disclosure on a phone), each
// chapter with its tasks, numbered steps and screenshots, the quick reference with CarmaCars' contact details from
// Site settings, search within the guide, the stored PDF and a print layout that matches it. The HTML was rendered
// from the guide's Markdown when it was published (web/src/features/guides/markdown.ts); nothing is rendered here.
export async function GuideView({ g, portal, pdfHref, admin = false }: { g: GuideData; portal: GuidePortal; pdfHref: string; admin?: boolean }) {
  const s = await getSettings();
  let n = 0;
  const numbered = g.sections.map((x) => ({ ...x, num: x.kind === 'chapter' ? ++n : null }));
  const taskList = (html: string) => [...html.matchAll(/<section class="gd-task" id="([^"]+)" data-gd-task><h2 class="gd-h2">(.*?)<\/h2>/g)]
    .map((m) => ({ id: m[1]!, title: m[2]!.replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&#39;/g, "'").replace(/&quot;/g, '"') }));
  const edition = g.published_at ? fmtDay(g.published_at) : null;
  return (
    <article className="gd" data-testid="guide" data-portal={portal} aria-labelledby="gd-title">
      <GuideSeen portal={portal} />
      <div className="gd-cover" aria-hidden="true">
        <div className="gd-wm">Carma<b>Cars</b></div>
        <div><p className="gd-kicker">User guide</p><h1>{g.title}</h1><div className="gd-rule" />{g.promise && <p>{g.promise}</p>}</div>
        <small>{s.site_url.replace(/^https?:\/\//, '')}{edition ? ` · Edition of ${edition}` : ''}</small>
      </div>
      <header className="gd-head">
        <p className="gd-kicker">User guide</p>
        <h1 className="gd-title" id="gd-title">{g.title}</h1>
        {g.promise && <p className="gd-promise">{g.promise}</p>}
        {g.version > 0 && <div className="gd-actions gd-noprint">
          {g.pdf ? <a className="btn btn--primary btn--sm" href={pdfHref} data-testid="guide-pdf">Download PDF</a> : null}
          <GuideTools mode="print" />
        </div>}
        {g.version > 0 && <p className="gd-pdfnote gd-noprint" data-testid="guide-pdf-note">
          {g.pdf ? <>PDF updated <b>{fmtDay(g.pdf.generated_at)}</b>{g.pdf.stale ? <>; the web guide has newer edits (updated {fmtDay(g.published_at!)}). &quot;Print or save as PDF&quot; always prints this page as it is now.</> : '.'}</>
            : <>No PDF is stored yet. &quot;Print or save as PDF&quot; makes one from this page.</>}
          {edition && !g.pdf?.stale ? <> Web guide updated {edition}.</> : null}
        </p>}
        {g.version > 0 && <GuideTools mode="search" />}
      </header>
      {g.version === 0 ? (
        <div className="gd-empty" data-testid="guide-empty"><p className="d4">This guide is being written.</p>
          <p className="muted">{admin ? 'Publish it in Admin > Settings > Guides.' : `Questions in the meantime: ${s.public_email ?? ''}${s.phone_display ? ` or ${s.phone_display}` : ''}.`}</p></div>
      ) : (<>
        <details className="gd-toc" data-testid="guide-toc">
          <summary>Contents</summary>
          <nav aria-label="Guide contents"><ol>
            {numbered.map((x) => (
              <li key={x.id}><a href={`#${x.slug}`}><span className="gd-tn">{x.num ? String(x.num).padStart(2, '0') : '→'}</span><b>{x.title}</b></a>
                {x.kind === 'chapter' && <ol>{taskList(x.html).map((t) => <li key={t.id}><a href={`#${t.id}`}>{t.title}</a></li>)}</ol>}</li>))}
          </ol></nav>
        </details>
        <div className="gd-body">
          {numbered.map((x) => (
            <section key={x.id} id={x.slug} className={`gd-sec gd-sec--${x.kind}`} data-gd-section aria-labelledby={`${x.slug}-t`}>
              <header className="gd-sec-head">
                {x.num ? <div className="gd-sec-num" aria-hidden="true">{String(x.num).padStart(2, '0')}</div> : null}
                <div><p className="gd-sec-kicker">{x.num ? `Chapter ${x.num}` : x.kind === 'start' ? 'Before you begin' : 'Keep this page handy'}</p>
                  <h2 className="gd-sec-title" id={`${x.slug}-t`}>{x.title}</h2></div>
              </header>
              {x.kind === 'start' && <div className="gd-signin"><span>Sign in at</span><b>{g.signin_url}</b>{g.lands_on && <small>You land on {g.lands_on}.</small>}</div>}
              <div className="gd-content" dangerouslySetInnerHTML={{ __html: x.html }} />
              {x.kind === 'reference' && (
                <div className="gd-contact" data-testid="guide-contact"><h3>Talk to us</h3>
                  <dl>{s.public_email && <div><dt>Email</dt><dd><a href={`mailto:${s.public_email}`}>{s.public_email}</a></dd></div>}
                    {s.phone_display && <div><dt>Phone</dt><dd><a href={`tel:${s.phone ?? s.phone_display}`}>{s.phone_display}</a></dd></div>}</dl>
                  <p>Tell us your name, the booking or car, and what you see on the screen.</p></div>)}
            </section>))}
        </div>
      </>)}
    </article>
  );
}
