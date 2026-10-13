'use client';

// The car from above (06-field.md sections 4 and 5): a tap marks where damage is (x and y from 0 to 1 are
// stored in condition_report_damages.position); existing marks are drawn as labelled circles. The written
// location in the damage form says the same in words, so the diagram is never the only way in.
export interface Mark { label: string; position?: { x: number; y: number } | null; old?: boolean }

export function CarDiagram({ marks, onPick, picked }: { marks: Mark[]; onPick?: (p: { x: number; y: number }) => void; picked?: { x: number; y: number } | null }) {
  return (
    <svg className="fd-car" viewBox="0 0 100 200" role="img" aria-label={`Car diagram, front at the top. ${marks.length ? `Marks: ${marks.map((m) => m.label).join(', ')}.` : 'No marks.'}`}
      onClick={(e) => {
        if (!onPick) return;
        const r = (e.currentTarget as SVGSVGElement).getBoundingClientRect();
        onPick({ x: Math.round(((e.clientX - r.left) / r.width) * 100) / 100, y: Math.round(((e.clientY - r.top) / r.height) * 100) / 100 });
      }} data-testid="car-diagram">
      <rect x="18" y="8" width="64" height="184" rx="22" fill="#fff" stroke="#111" strokeWidth="2" />
      <rect x="26" y="48" width="48" height="30" rx="6" fill="#e9eef2" stroke="#111" />
      <rect x="26" y="128" width="48" height="24" rx="6" fill="#e9eef2" stroke="#111" />
      <rect x="10" y="34" width="8" height="26" rx="3" fill="#111" /><rect x="82" y="34" width="8" height="26" rx="3" fill="#111" />
      <rect x="10" y="140" width="8" height="26" rx="3" fill="#111" /><rect x="82" y="140" width="8" height="26" rx="3" fill="#111" />
      <text x="50" y="22" textAnchor="middle" fontSize="8" fill="#111">FRONT</text>
      <text x="50" y="186" textAnchor="middle" fontSize="8" fill="#111">REAR</text>
      {marks.filter((m) => m.position).map((m) => (
        <g key={m.label} transform={`translate(${m.position!.x * 100} ${m.position!.y * 200})`}>
          <circle r="6" fill={m.old ? '#fff' : '#b00020'} stroke="#b00020" strokeWidth="2" />
          <text y="3" textAnchor="middle" fontSize="6" fill={m.old ? '#b00020' : '#fff'}>{m.label}</text>
        </g>
      ))}
      {picked && <circle cx={picked.x * 100} cy={picked.y * 200} r="7" fill="none" stroke="#111" strokeWidth="2" strokeDasharray="3 2" />}
    </svg>
  );
}
