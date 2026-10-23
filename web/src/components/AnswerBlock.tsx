// The short answer at the top of a key page (docs/changes/2026-10-23-ai-search.md): one sentence on who, what, where,
// the price from and how to book, the facts as rows, and the day those facts last changed. People skim it; AI answer
// engines quote it. Every value comes from the database; a row without a value is left out, never filled in.
const fmt = (d: string) => new Date(`${d.slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-CA', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });

export function AnswerBlock({ lead, rows, updated, title = 'The short answer' }: { lead: string; rows: Array<[string, string]>; updated?: string | null; title?: string }) {
  return (
    <section className="section--tight answer" aria-labelledby="h-answer" data-testid="answer-block">
      <div className="wrap stack">
        <h2 className="d3" id="h-answer">{title}</h2>
        <p className="lead measure" data-testid="answer-lead">{lead}</p>
        {rows.length > 0 && <table className="spec measure"><tbody>{rows.map(([k, v]) => <tr key={k}><th scope="row">{k}</th><td>{v}</td></tr>)}</tbody></table>}
        {updated && /^\d{4}-\d{2}-\d{2}/.test(updated) && <p className="small muted">Updated <time dateTime={updated.slice(0, 10)}>{fmt(updated)}</time></p>}
      </div>
    </section>
  );
}
