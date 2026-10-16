'use client';
import '@/styles/guide.css';
import { useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { render } from './markdown';
import { deleteGuideSection, guideVersion, moveGuideSection, publishGuide, resolveGuideReview, saveGuideSection, suggestGuideText, uploadGuideImage, uploadGuidePdf } from '@/server/actions/guides';

// Admin > Settings > Guides > a guide (migration 0044): the chapters in order, a Markdown editor with the preview the
// readers will see (the same renderer as publishing), version history, screenshots, publishing and the stored PDF.
export interface EditorSection { id: string; kind: 'start' | 'chapter' | 'reference'; slug: string; sort_order: number; title: string; blurb: string | null; body_md: string;
  is_hidden: boolean; draft_version: number; published_version: number | null; published_at: string | null; changed: boolean; updated_at: string; updated_by_name: string | null;
  history: Array<{ version: number; published: boolean; title: string; saved_at: string; saved_by_name: string | null; chars: number }>;
  /** 0049: a screenshot of this section changed on the last upkeep run */
  needs_review?: boolean; review_note?: string | null; review_images?: Array<{ old_url: string; new_url: string; diff: number | null; at: string }>;
  suggestion_md?: string | null; suggestion_at?: string | null; suggestion_model?: string | null }
export interface EditorGuide { portal: string; title: string; version: number; published_at: string | null; published_by_name: string | null; sections: EditorSection[];
  pdf: { generated_at: string; source: string; bytes: number; guide_version: number | null } | null; images: Array<{ id: string; url: string; alt: string | null; created_at: string }> }

const when = (iso: string | null) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso)) : '');
const KIND: Record<string, string> = { start: 'Start page', chapter: 'Chapter', reference: 'Quick reference' };

const HELP: Array<[string, string]> = [
  ['## Task title', 'A task: listed under its chapter in the contents, found by search'],
  ['1. Press **Save**.', 'Numbered steps; **bold** is a button or label as it reads on the screen'],
  ['`carmacars.ca/owner`', 'An address'],
  ['![What it shows](url "phone")', 'A screenshot; after steps it sits beside them (phone) or below (desktop). Add pins: 1 40 20 (number, % from left, % from top)'],
  ['> Tip: text', 'A box. Also Good to know, Note, Watch out, Important'],
  ['| A | B |', 'A table: a header row, then | --- | --- |, then the rows'],
  [':::flow', 'Stages in a row: lines of Title | what happens, then :::'],
  [':::phones', 'Phone screens side by side: lines of 1. caption ![](url "phone"), then :::']
];

function Problem({ res }: { res: { ok: boolean; message?: string } | null }) {
  return res && !res.ok ? <p className="alert alert--error" role="alert"><span>{res.message}</span></p> : null;
}

export function GuideEditor({ g, portal, initial }: { g: EditorGuide; portal: string; initial: string | null }) {
  const router = useRouter();
  const [sel, setSel] = useState<string>(initial && g.sections.some((s) => s.id === initial) ? initial : g.sections[0]?.id ?? 'new');
  const changed = g.sections.filter((s) => s.changed).length;
  const pub = useAct<{ version: number; sections_changed: number }>();
  const mv = useAct();
  const cur = g.sections.find((s) => s.id === sel) ?? null;
  return (
    <div className="ad-cols ad-cols--main" data-testid="guide-editor">
      <div className="stack-lg">
        <section className="pt-card" aria-labelledby="ge-pub">
          <div className="pt-card__head"><h2 className="d4" id="ge-pub">Publish</h2>
            <span className="small muted">{g.version ? `Version ${g.version}, published ${when(g.published_at)}${g.published_by_name ? ` by ${g.published_by_name}` : ''}` : 'Not published yet'}</span></div>
          <p className="small">{changed ? `${changed} section${changed === 1 ? ' has' : 's have'} changes readers do not see yet.` : 'Readers see every saved change.'} Publishing renders every chapter once and puts it in front of the portal&apos;s people at once.</p>
          <Problem res={pub.res} />
          {pub.res?.ok && <p className="alert alert--ok" role="status"><span>Published as version {pub.res.data.version}.</span></p>}
          <div className="row"><button type="button" className="btn btn--primary btn--sm" disabled={pub.pending} data-testid="guide-publish"
            onClick={() => pub.run(() => publishGuide(portal), (r) => { if (r.ok) router.refresh(); })}>{pub.pending ? 'Publishing' : `Publish version ${g.version + 1}`}</button></div>
        </section>
        {cur && (cur.needs_review || cur.suggestion_md) && <ReviewPanel key={`rv-${cur.id}:${cur.suggestion_at ?? ''}`} portal={portal} s={cur} onDone={() => router.refresh()} />}
        {sel === 'new' ? <SectionForm key="new" portal={portal} section={null} after={g.sections.filter((s) => s.kind !== 'reference').at(-1)?.id ?? null} onSaved={(id) => { setSel(id); router.refresh(); }} />
          : cur ? <SectionForm key={`${cur.id}:${cur.draft_version}`} portal={portal} section={cur} onSaved={() => router.refresh()} onDeleted={() => { setSel(g.sections[0]?.id ?? 'new'); router.refresh(); }} />
          : null}
        <ImageTools portal={portal} images={g.images} sections={g.sections} />
        <PdfCard portal={portal} g={g} />
      </div>
      <aside className="stack-lg">
        <section className="pt-card" aria-labelledby="ge-sec">
          <div className="pt-card__head"><h2 className="d4" id="ge-sec">Chapters</h2><button type="button" className="btn btn--ghost btn--sm" onClick={() => setSel('new')} data-testid="guide-add">Add a chapter</button></div>
          <Problem res={mv.res} />
          <ol className="ad-list" style={{ listStyle: 'none', margin: 0, padding: 0, display: 'grid', gap: 'var(--s-2)' }} data-testid="guide-sections">
            {g.sections.map((s) => (
              <li key={s.id} style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) auto', gap: 'var(--s-2)', alignItems: 'center', padding: 'var(--s-2)', border: '1px solid var(--grey-200)', background: s.id === sel ? 'var(--grey-50)' : 'var(--white)' }}>
                <button type="button" className="link" style={{ textAlign: 'left', background: 'none', border: 0, padding: 0, cursor: 'pointer' }} onClick={() => setSel(s.id)} aria-current={s.id === sel ? 'true' : undefined} data-testid={`guide-section-${s.slug}`}>
                  <b>{s.title}</b>{s.needs_review ? <> <span className="badge badge--red" data-testid="guide-needs-review">Needs review</span></> : null}<br /><span className="small muted">{KIND[s.kind]}{s.is_hidden ? ', hidden' : ''}{s.changed ? ', changes not published' : s.published_version ? ', published' : ', not published'}</span>
                </button>
                {s.kind === 'chapter' && <span className="row" style={{ gap: 2 }}>
                  <button type="button" className="btn btn--quiet btn--sm" aria-label={`Move ${s.title} up`} disabled={mv.pending} onClick={() => mv.run(() => moveGuideSection(portal, s.id, 'up'), () => router.refresh())}>&uarr;</button>
                  <button type="button" className="btn btn--quiet btn--sm" aria-label={`Move ${s.title} down`} disabled={mv.pending} onClick={() => mv.run(() => moveGuideSection(portal, s.id, 'down'), () => router.refresh())}>&darr;</button>
                </span>}
              </li>))}
          </ol>
          <p className="small muted">Moving a chapter changes the published guide at once; text changes wait for Publish.</p>
        </section>
        <section className="pt-card" aria-labelledby="ge-help"><h2 className="d4" id="ge-help">How to write it</h2>
          <dl className="pt-dl small">{HELP.map(([k, v]) => <div key={k}><dt><code>{k}</code></dt><dd>{v}</dd></div>)}</dl></section>
      </aside>
    </div>
  );
}

function SectionForm({ portal, section, after, onSaved, onDeleted }: { portal: string; section: EditorSection | null; after?: string | null; onSaved: (id: string) => void; onDeleted?: () => void }) {
  const [title, setTitle] = useState(section?.title ?? '');
  const [blurb, setBlurb] = useState(section?.blurb ?? '');
  const [body, setBody] = useState(section?.body_md ?? '');
  const [hidden, setHidden] = useState(section?.is_hidden ?? false);
  const [preview, setPreview] = useState(true);
  const area = useRef<HTMLTextAreaElement>(null);
  const save = useAct<{ id: string; draft_version: number }>();
  const del = useAct();
  const ver = useAct<{ title: string; blurb: string | null; body_md: string }>();
  const out = useMemo(() => render(body, { idPrefix: section?.slug ?? 'new' }), [body, section?.slug]);
  const dirty = !section || title !== section.title || (blurb || '') !== (section.blurb || '') || body !== section.body_md || hidden !== section.is_hidden;
  const id = section?.id ?? 'new';
  return (
    <section className="pt-card" aria-labelledby={`ge-f-${id}`} data-testid="guide-section-form">
      <div className="pt-card__head"><h2 className="d4" id={`ge-f-${id}`}>{section ? `${KIND[section.kind]}: ${section.title}` : 'New chapter'}</h2>
        {section && <span className="small muted">Draft {section.draft_version}{section.published_version ? `, published ${section.published_version}` : ''}{section.updated_by_name ? `, saved by ${section.updated_by_name}` : ''}</span>}</div>
      <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); save.run(() => saveGuideSection({ id: section?.id, portal, kind: section?.kind ?? 'chapter', title, blurb, body_md: body, is_hidden: hidden, after: after ?? undefined }), (r) => { if (r.ok) onSaved(r.data.id); }); }}>
        <div className="field-row">
          <div className="field"><label className="label" htmlFor={`ge-t-${id}`}>Title</label><input className="input" id={`ge-t-${id}`} value={title} onChange={(e) => setTitle(e.target.value)} maxLength={120} required data-testid="guide-title" /></div>
          <div className="field"><label className="label" htmlFor={`ge-b-${id}`}>Line in the contents <span className="opt">(optional)</span></label><input className="input" id={`ge-b-${id}`} value={blurb} onChange={(e) => setBlurb(e.target.value)} maxLength={300} /></div>
        </div>
        <div className="field"><label className="label" htmlFor={`ge-m-${id}`}>Text</label>
          <textarea ref={area} className="textarea" id={`ge-m-${id}`} value={body} onChange={(e) => setBody(e.target.value)} rows={18} spellCheck style={{ fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace', fontSize: '0.875rem', minHeight: '20rem' }} data-testid="guide-body" />
          {out.warnings.length > 0 && <ul className="small" role="alert" style={{ color: 'var(--red-700)' }}>{out.warnings.map((w) => <li key={w}>{w}</li>)}</ul>}
        </div>
        <label className="row small"><input type="checkbox" checked={hidden} onChange={(e) => setHidden(e.target.checked)} /> Hidden (not in the published guide)</label>
        <Problem res={save.res} />
        {save.res?.ok && !dirty && <p className="alert alert--ok" role="status"><span>Saved. Publish to show it to readers.</span></p>}
        <div className="row" style={{ flexWrap: 'wrap' }}>
          <button className="btn btn--primary btn--sm" type="submit" disabled={save.pending || !dirty} data-testid="guide-save">{save.pending ? 'Saving' : 'Save the draft'}</button>
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => setPreview(!preview)} aria-pressed={preview}>{preview ? 'Hide the preview' : 'Show the preview'}</button>
          {section && !section.published_at && section.kind === 'chapter' && <button className="btn btn--quiet btn--sm" type="button" disabled={del.pending} onClick={() => { if (window.confirm('Delete this chapter? It was never published.')) del.run(() => deleteGuideSection(portal, section.id), (r) => { if (r.ok) onDeleted?.(); }); }}>Delete</button>}
        </div>
        <Problem res={del.res} />
      </form>
      {preview && <div className="gd" style={{ border: '1px dashed var(--grey-300)', padding: 'var(--s-4)' }} data-testid="guide-preview" aria-label="Preview">
        <div className="gd-body"><section className="gd-sec"><header className="gd-sec-head"><div><p className="gd-sec-kicker">Preview</p><h2 className="gd-sec-title">{title || 'Untitled'}</h2></div></header>
          <div className="gd-content" dangerouslySetInnerHTML={{ __html: out.html }} /></section></div></div>}
      {section && section.history.length > 0 && <details><summary className="link">Earlier versions ({section.history.length})</summary>
        <ul className="small" style={{ display: 'grid', gap: 'var(--s-2)', marginTop: 'var(--s-2)' }}>{section.history.map((h) => (
          <li key={`${h.version}-${h.published}`}>{h.published ? 'Published' : 'Draft'} {h.version}, {when(h.saved_at)}{h.saved_by_name ? ` by ${h.saved_by_name}` : ''} ({h.chars} characters){' '}
            <button type="button" className="btn btn--quiet btn--sm" disabled={ver.pending} onClick={() => ver.run(() => guideVersion(section.id, h.version, h.published), (r) => { if (r.ok) { setTitle(r.data.title); setBlurb(r.data.blurb ?? ''); setBody(r.data.body_md); } })}>Put this text back in the editor</button></li>))}
        </ul><p className="small muted">Putting a text back fills the editor; save it to keep it.</p><Problem res={ver.res} /></details>}
    </section>
  );
}

function imageSize(file: File): Promise<{ width: number; height: number } | null> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => { resolve({ width: img.naturalWidth, height: img.naturalHeight }); URL.revokeObjectURL(url); };
    img.onerror = () => { resolve(null); URL.revokeObjectURL(url); };
    img.src = url;
  });
}

function ImageTools({ portal, images, sections }: { portal: string; images: EditorGuide['images']; sections: EditorSection[] }) {
  const up = useAct<{ url: string; markdown: string; sections_changed: number }>();
  const router = useRouter();
  const [frame, setFrame] = useState<'desktop' | 'phone'>('desktop');
  const [alt, setAlt] = useState('');
  const [replaces, setReplaces] = useState('');
  const used = useMemo(() => [...new Set(sections.flatMap((s) => [...s.body_md.matchAll(/!\[[^\]]*\]\(([^)\s"]+)/g)].map((m) => m[1]!)))].sort(), [sections]);
  return (
    <section className="pt-card" aria-labelledby="ge-img">
      <div className="pt-card__head"><h2 className="d4" id="ge-img">Screenshots</h2></div>
      <p className="small">Upload a screenshot (JPEG or PNG). You get the line to paste into a chapter. To change a screenshot everywhere it is shown, choose it under &quot;Replaces&quot;: every draft that shows it then shows the new one (publish to show readers).</p>
      <form className="stack" noValidate onSubmit={async (e) => {
        e.preventDefault();
        const fd = new FormData(e.currentTarget);
        const file = fd.get('file');
        if (file instanceof File && file.size) { const sz = await imageSize(file); if (sz) { fd.set('width', String(sz.width)); fd.set('height', String(sz.height)); } }
        up.run(() => uploadGuideImage(fd), (r) => { if (r.ok && r.data.sections_changed) router.refresh(); });
      }}>
        <input type="hidden" name="portal" value={portal} />
        <div className="field-row">
          <div className="field"><label className="label" htmlFor="ge-file">Image</label><input className="input" id="ge-file" name="file" type="file" accept="image/jpeg,image/png,image/webp" data-testid="guide-image-file" /></div>
          <div className="field"><label className="label" htmlFor="ge-frame">Shown as</label>
            <select className="select" id="ge-frame" name="frame" value={frame} onChange={(e) => setFrame(e.target.value as 'desktop' | 'phone')}><option value="desktop">A computer screen</option><option value="phone">A phone screen</option></select></div>
        </div>
        <div className="field-row">
          <div className="field"><label className="label" htmlFor="ge-alt">What it shows <span className="opt">(read aloud to screen reader users)</span></label><input className="input" id="ge-alt" name="alt" value={alt} onChange={(e) => setAlt(e.target.value)} /></div>
          <div className="field"><label className="label" htmlFor="ge-rep">Replaces <span className="opt">(optional)</span></label>
            <select className="select" id="ge-rep" name="replaces" value={replaces} onChange={(e) => setReplaces(e.target.value)}><option value="">Nothing, a new screenshot</option>{used.map((u) => <option key={u} value={u}>{u.split('/').pop()}</option>)}</select></div>
        </div>
        <Problem res={up.res} />
        {up.res?.ok && <div className="alert alert--ok" role="status"><span>Uploaded{up.res.data.sections_changed ? `, and ${up.res.data.sections_changed} draft${up.res.data.sections_changed === 1 ? '' : 's'} now show it` : ''}. Paste this line into a chapter:</span>
          <input className="input pt-mono" readOnly value={up.res.data.markdown} onFocus={(e) => e.currentTarget.select()} aria-label="Line to paste" data-testid="guide-image-line" /></div>}
        <div className="row"><button className="btn btn--ghost btn--sm" type="submit" disabled={up.pending} data-testid="guide-image-upload">{up.pending ? 'Uploading' : 'Upload'}</button></div>
      </form>
      {images.length > 0 && <details><summary className="link small">Uploaded before ({images.length})</summary>
        <ul className="small">{images.map((i) => <li key={i.id}><span className="pt-mono">{i.url}</span>{i.alt ? ` (${i.alt})` : ''}</li>)}</ul></details>}
    </section>
  );
}

function PdfCard({ portal, g }: { portal: string; g: EditorGuide }) {
  const up = useAct();
  const router = useRouter();
  const stale = g.pdf && g.published_at && new Date(g.published_at) > new Date(g.pdf.generated_at);
  return (
    <section className="pt-card" aria-labelledby="ge-pdf">
      <div className="pt-card__head"><h2 className="d4" id="ge-pdf">PDF</h2></div>
      <p className="small" data-testid="guide-pdf-status">{g.pdf ? <>The stored PDF is from {when(g.pdf.generated_at)} ({g.pdf.source === 'committed' ? 'the October 2026 edition' : g.pdf.source === 'generated' ? `printed from version ${g.pdf.guide_version}` : 'uploaded by an Admin'}, {(g.pdf.bytes / 1e6).toFixed(1)} MB).{stale ? ' The published guide is newer: the guide page says so and offers "Print or save as PDF".' : ''}</> : 'No PDF is stored for this guide yet.'}</p>
      <p className="small muted">To store a PDF of the guide as it is now, run the guides-pdf workflow on GitHub, or open the guide, use &quot;Print or save as PDF&quot; and upload the file here.</p>
      <form className="row" style={{ flexWrap: 'wrap' }} noValidate onSubmit={(e) => { e.preventDefault(); const fd = new FormData(e.currentTarget); up.run(() => uploadGuidePdf(fd), (r) => { if (r.ok) router.refresh(); }); }}>
        <input type="hidden" name="portal" value={portal} /><input type="hidden" name="version" value={String(g.version)} />
        <label className="vh" htmlFor="ge-pdf-file">PDF file</label><input className="input" id="ge-pdf-file" name="file" type="file" accept="application/pdf" style={{ maxWidth: '22rem' }} />
        <button className="btn btn--ghost btn--sm" type="submit" disabled={up.pending}>{up.pending ? 'Uploading' : 'Store this PDF'}</button>
      </form>
      <Problem res={up.res} />
      {up.res?.ok && <p className="alert alert--ok" role="status"><span>Stored. The guide now offers this PDF.</span></p>}
    </section>
  );
}

// A section whose screenshot changed on the guide upkeep run (migration 0049): the old and new screenshot, a suggested
// text from Workers AI on request, and the Admin's answer (use it as the draft, dismiss it, or mark the section reviewed).
function ReviewPanel({ portal, s, onDone }: { portal: string; s: EditorSection; onDone: () => void }) {
  const sug = useAct<{ summary: string }>();
  const act = useAct();
  const preview = useMemo(() => (s.suggestion_md ? render(s.suggestion_md, { idPrefix: `${s.slug}-sug` }) : null), [s.suggestion_md, s.slug]);
  const img = s.review_images?.at(-1);
  return (
    <section className="pt-card stack" aria-labelledby={`rv-${s.id}`} data-testid="guide-review">
      <div className="pt-card__head"><h2 className="d4" id={`rv-${s.id}`}>Needs review: {s.title}</h2>{img?.at && <span className="small muted">{when(img.at)}</span>}</div>
      {s.review_note && <p className="small">{s.review_note}</p>}
      {img && <div className="ad-cols ad-cols--2">
        <figure className="stack"><figcaption className="small muted">Before</figcaption>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={img.old_url} alt={`The screen before, in ${s.title}`} style={{ maxWidth: '100%', border: '1px solid var(--grey-200)' }} /></figure>
        <figure className="stack"><figcaption className="small muted">Now (already in the guide){img.diff ? `, ${Math.round(img.diff * 100)}% different` : ''}</figcaption>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={img.new_url} alt={`The screen now, in ${s.title}`} style={{ maxWidth: '100%', border: '1px solid var(--grey-200)' }} /></figure>
      </div>}
      <p className="small muted">The new screenshot already shows in the guide. Read the text against it: if the steps and labels still match, mark it reviewed. Workers AI can suggest a text for you to check.</p>
      <Problem res={sug.res} /><Problem res={act.res} />
      {sug.res?.ok && sug.res.data.summary && <p className="small" role="status">{sug.res.data.summary}</p>}
      {preview && <div className="stack" data-testid="guide-suggestion"><p className="small"><b>Suggested text</b>{s.suggestion_model ? ` (${s.suggestion_model})` : ''}</p>
        <div className="gd-preview" style={{ border: '1px solid var(--grey-200)', padding: 'var(--s-3)', maxHeight: '28rem', overflow: 'auto' }} dangerouslySetInnerHTML={{ __html: preview.html }} /></div>}
      <div className="row" style={{ flexWrap: 'wrap' }}>
        {!s.suggestion_md && <button type="button" className="btn btn--ghost btn--sm" disabled={sug.pending} onClick={() => sug.run(() => suggestGuideText(portal, s.id), (r) => { if (r.ok) onDone(); })} data-testid="guide-suggest">{sug.pending ? 'Asking' : 'Suggest a text update'}</button>}
        {s.suggestion_md && <button type="button" className="btn btn--primary btn--sm" disabled={act.pending} onClick={() => act.run(() => resolveGuideReview(portal, s.id, 'apply_suggestion'), (r) => { if (r.ok) onDone(); })} data-testid="guide-apply-suggestion">Use this text as the draft</button>}
        {s.suggestion_md && <button type="button" className="btn btn--quiet btn--sm" disabled={act.pending} onClick={() => act.run(() => resolveGuideReview(portal, s.id, 'dismiss_suggestion'), (r) => { if (r.ok) onDone(); })}>Dismiss the suggestion</button>}
        {s.needs_review && <button type="button" className="btn btn--ghost btn--sm" disabled={act.pending} onClick={() => act.run(() => resolveGuideReview(portal, s.id, 'reviewed'), (r) => { if (r.ok) onDone(); })} data-testid="guide-reviewed">Mark reviewed</button>}
      </div>
    </section>
  );
}
