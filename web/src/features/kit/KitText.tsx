import type { KitSection } from './index';

// The kit's sections on a page (docs/changes/2026-10-24-writing-kit.md): plain headings and paragraphs, no client code.
// "hub" pages use the landing sections' look, "vehicle" pages the vehicle sections'. data-kit-source says where the
// words came from (written for the page, or the kit), for the end-to-end tests and the SEO audit.
export function KitText({ sections, source, look }: { sections: KitSection[]; source: 'written' | 'kit'; look: 'hub' | 'vehicle' }) {
  if (!sections.length) return null;
  return (
    <div className="kit-text" data-testid="kit-text" data-kit-source={source}>
      {sections.map((s) => (
        <section key={s.id} className={look === 'hub' ? 'car-sec landing__sec' : 'vp-sec'} aria-labelledby={`h-kit-${s.id}`} data-kit-section={s.id}>
          <h2 className={look === 'hub' ? 'd2' : 'd3'} id={`h-kit-${s.id}`}>{s.heading}</h2>
          {s.paras.map((p, i) => <p key={i} className="measure">{p}</p>)}
        </section>
      ))}
    </div>
  );
}
