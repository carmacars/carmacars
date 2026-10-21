// A page's outline while it loads (app/**/loading.tsx): the heading, a line and a grid of cards, in the page's own
// widths, so nothing moves when the content arrives.
export function PageSkeleton({ cards = 6, label = 'Loading' }: { cards?: number; label?: string }) {
  return (
    <div className="wrap sk-page" role="status" aria-live="polite" aria-busy="true">
      <span className="vh">{label}</span>
      <div className="skeleton sk-title" aria-hidden="true" />
      <div className="skeleton sk-line" style={{ width: '60%' }} aria-hidden="true" />
      <div className="sk-grid" aria-hidden="true">
        {Array.from({ length: cards }, (_, i) => (
          <div key={i} className="sk-card"><div className="skeleton sk-media" /><div className="skeleton sk-line" style={{ width: '70%' }} /><div className="skeleton sk-line" style={{ width: '40%' }} /></div>
        ))}
      </div>
    </div>
  );
}
