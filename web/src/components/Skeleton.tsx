// Skeleton lines while something loads (instead of a spinner or the word alone). Screen readers hear "Loading".
export function SkeletonLines({ lines = 3, title = false }: { lines?: number; title?: boolean }) {
  return (
    <div className="sk-stack" role="status">
      <span className="vh">Loading</span>
      {title && <div className="skeleton sk-title" aria-hidden="true" />}
      {Array.from({ length: lines }, (_, i) => <div key={i} className="skeleton sk-line" aria-hidden="true" />)}
    </div>
  );
}
