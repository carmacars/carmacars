// While a /va page reads (October 25, 2026): the shape of the page in grey, so nothing jumps when it arrives. Screen
// readers hear one status line. The shimmer runs only under prefers-reduced-motion: no-preference (va.css).
export default function Loading() {
  return (
    <div className="va-skel" role="status" aria-live="polite" data-testid="va-loading">
      <span className="vh">Loading</span>
      <div className="va-skel__hero" aria-hidden="true" />
      <div className="va-skel__row" aria-hidden="true">{[0, 1, 2, 3].map((i) => <div key={i} className="va-skel__block va-skel__tile" />)}</div>
      <div className="va-skel__block va-skel__line" aria-hidden="true" />
      <div className="va-skel__block va-skel__line" aria-hidden="true" />
    </div>
  );
}
