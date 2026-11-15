// r48 (owner, Nov 14): "There should be an example of an endorsement page and a pink slip for that error and not just
// words." Two drawn examples (made up: Example Insurance Co., fake numbers, an EXAMPLE watermark, no real logos), each
// with the parts that must show circled and numbered, and short steps: where to find it, how to photograph it, and why
// we refuse one. Shown beside each upload on the verify page and with a refusal. No state, so it renders on the server.
import './coverage-examples.css';

const RED = 'var(--red-600, #c8102e)';

function Mark({ cx, cy, rx, ry, n }: { cx: number; cy: number; rx: number; ry: number; n: number }) {
  return (
    <g>
      <ellipse cx={cx} cy={cy} rx={rx} ry={ry} fill="none" stroke={RED} strokeWidth="3" strokeDasharray="7 4" />
      <circle cx={cx + rx - 4} cy={cy - ry + 2} r="11" fill={RED} />
      <text x={cx + rx - 4} y={cy - ry + 6.5} textAnchor="middle" fontSize="13" fontWeight="700" fill="#fff">{n}</text>
    </g>
  );
}

function Watermark({ x, y, rotate }: { x: number; y: number; rotate: number }) {
  return <text x={x} y={y} transform={`rotate(${rotate} ${x} ${y})`} textAnchor="middle" fontSize="54" fontWeight="800" fill="#000" opacity="0.08" letterSpacing="8">EXAMPLE</text>;
}

/** An Ontario liability insurance card (the pink slip), made up. */
export function PinkSlipExample() {
  return (
    <svg className="cx-img" viewBox="0 0 440 270" role="img" aria-labelledby="cx-pink-t" data-testid="example-pink-slip">
      <title id="cx-pink-t">Example pink slip: the insurance card for your own car, with the 4 parts that must show circled: your name, the policy number, the dates, the insurer</title>
      <rect x="6" y="6" width="428" height="258" rx="10" fill="#f7d3de" stroke="#b9788c" strokeWidth="2" />
      <text x="24" y="36" fontSize="13" fontWeight="700" fill="#5b2333">ONTARIO STANDARD AUTOMOBILE POLICY</text>
      <text x="24" y="54" fontSize="12" fill="#5b2333">Liability insurance card (keep in the car)</text>
      <text x="24" y="84" fontSize="11" fill="#7a4152">INSURER</text>
      <text x="24" y="101" fontSize="15" fontWeight="700" fill="#2b0f18">Example Insurance Co.</text>
      <text x="24" y="130" fontSize="11" fill="#7a4152">NAMED INSURED</text>
      <text x="24" y="147" fontSize="15" fontWeight="700" fill="#2b0f18">ALEX SAMPLE</text>
      <text x="250" y="130" fontSize="11" fill="#7a4152">POLICY NUMBER</text>
      <text x="250" y="147" fontSize="15" fontWeight="700" fill="#2b0f18">EX-000-123456</text>
      <text x="24" y="178" fontSize="11" fill="#7a4152">EFFECTIVE</text>
      <text x="24" y="195" fontSize="14" fontWeight="700" fill="#2b0f18">2026-01-01</text>
      <text x="130" y="178" fontSize="11" fill="#7a4152">EXPIRY</text>
      <text x="130" y="195" fontSize="14" fontWeight="700" fill="#2b0f18">2027-01-01</text>
      <text x="250" y="178" fontSize="11" fill="#7a4152">VEHICLE</text>
      <text x="250" y="195" fontSize="13" fill="#2b0f18">2020 Sample Sedan</text>
      <text x="24" y="240" fontSize="10" fill="#7a4152">Illustration only. Not a real policy.</text>
      <Watermark x={220} y={170} rotate={-14} />
      <Mark cx={95} cy={142} rx={82} ry={22} n={1} />
      <Mark cx={322} cy={142} rx={82} ry={22} n={2} />
      <Mark cx={110} cy={189} rx={98} ry={22} n={3} />
      <Mark cx={104} cy={95} rx={90} ry={20} n={4} />
    </svg>
  );
}

/** A policy page listing the OPCF 27 endorsement (Liability for Damage to Non-Owned Automobiles), made up. */
export function EndorsementExample() {
  return (
    <svg className="cx-img" viewBox="0 0 440 330" role="img" aria-labelledby="cx-end-t" data-testid="example-endorsement">
      <title id="cx-end-t">Example policy page with the OPCF 27 endorsement line circled, and your name, the policy number, the dates and the insurer</title>
      <rect x="6" y="6" width="428" height="318" rx="6" fill="#fff" stroke="#9a9a9a" strokeWidth="2" />
      <text x="24" y="34" fontSize="15" fontWeight="700" fill="#111">Example Insurance Co.</text>
      <text x="24" y="52" fontSize="12" fill="#444">Certificate of Automobile Insurance: declarations page</text>
      <text x="24" y="80" fontSize="11" fill="#666">Named insured</text>
      <text x="24" y="96" fontSize="14" fontWeight="700" fill="#111">ALEX SAMPLE</text>
      <text x="250" y="80" fontSize="11" fill="#666">Policy number</text>
      <text x="250" y="96" fontSize="14" fontWeight="700" fill="#111">EX-000-123456</text>
      <text x="24" y="124" fontSize="11" fill="#666">Policy period</text>
      <text x="24" y="140" fontSize="13" fontWeight="700" fill="#111">2026-01-01 to 2027-01-01</text>
      <line x1="24" y1="158" x2="416" y2="158" stroke="#ccc" />
      <text x="24" y="178" fontSize="12" fontWeight="700" fill="#111">Endorsements (OPCF)</text>
      <text x="24" y="200" fontSize="12" fill="#444">OPCF 20  Loss of Use</text>
      <text x="24" y="226" fontSize="12" fontWeight="700" fill="#111">OPCF 27  Liability for Damage to Non-Owned Automobiles</text>
      <text x="24" y="252" fontSize="12" fill="#444">OPCF 44R  Family Protection Coverage</text>
      <text x="24" y="300" fontSize="10" fill="#666">Illustration only. Not a real policy.</text>
      <Watermark x={220} y={210} rotate={-14} />
      <Mark cx={208} cy={222} rx={198} ry={18} n={1} />
      <Mark cx={95} cy={91} rx={82} ry={18} n={2} />
      <Mark cx={322} cy={91} rx={82} ry={18} n={3} />
      <Mark cx={110} cy={135} rx={98} ry={18} n={4} />
      <Mark cx={100} cy={29} rx={86} ry={16} n={5} />
    </svg>
  );
}

const PINK_PARTS = ['Your name', 'The policy number', 'The dates (it must still be valid after your return)', 'The insurer'];
const END_PARTS = ['The line "OPCF 27 Liability for Damage to Non-Owned Automobiles"', 'Your name', 'The policy number', 'The policy dates', 'The insurer'];

/** Where to find it, how to photograph it. */
export function CoverageHowTo() {
  return (
    <div className="cx-how" data-testid="coverage-howto">
      <p className="cx-how__t"><b>Where to find it</b></p>
      <ol className="small">
        <li>Open your insurance company&apos;s app or website and look for &quot;Documents&quot; or &quot;Pink slip&quot;.</li>
        <li>Or search your email for the policy your insurer sent you (often a PDF).</li>
        <li>Or look in your car&apos;s glovebox: the pink slip is kept there.</li>
        <li>No OPCF 27 line? Call your insurer and ask them to add &quot;OPCF 27&quot; to your policy. It is often free or a few dollars.</li>
      </ol>
      <p className="cx-how__t"><b>How to take the photo</b></p>
      <ol className="small">
        <li>Put the page flat on a table.</li>
        <li>All four corners must be in the photo.</li>
        <li>No glare: turn off the flash, move away from the lamp.</li>
        <li>Check you can read every word before you send it. A PDF from your insurer is even better.</li>
      </ol>
    </div>
  );
}

/** Why we send one back, in plain words. */
export const REFUSED_WHY = [
  'It is not the right page (for example a bill or a renewal letter instead of the pink slip or the OPCF 27 page).',
  'The OPCF 27 line is not on it.',
  'The name is not yours, or the policy ends before your return.',
  'We cannot read it: blurry, cut off, or glare on it.'
];

/** One example with its numbered parts: the pink slip or the endorsement page. */
export function CoverageExample({ kind }: { kind: 'pink_slip' | 'endorsement' }) {
  const parts = kind === 'pink_slip' ? PINK_PARTS : END_PARTS;
  return (
    <figure className="cx" data-testid={`example-${kind}`}>
      {kind === 'pink_slip' ? <PinkSlipExample /> : <EndorsementExample />}
      <figcaption className="small">
        <b>{kind === 'pink_slip' ? 'This is a pink slip.' : 'This is an OPCF 27 endorsement page.'}</b> Yours must show the circled parts:
        <ol className="cx__parts">{parts.map((p) => <li key={p}>{p}</li>)}</ol>
      </figcaption>
    </figure>
  );
}

/** Both examples, the steps, and (after a refusal) why one is sent back. */
export function CoverageExamples({ open = false, refused = false }: { open?: boolean; refused?: boolean }) {
  return (
    <details className="cx-all" open={open} data-testid="coverage-examples">
      <summary className="small"><b>See what to send: examples of a pink slip and an OPCF 27 page</b></summary>
      <div className="cx-grid">
        <CoverageExample kind="pink_slip" />
        <CoverageExample kind="endorsement" />
      </div>
      <CoverageHowTo />
      {refused && (
        <div className="cx-how" data-testid="coverage-refused-why">
          <p className="cx-how__t"><b>Why we send one back</b></p>
          <ul className="small">{REFUSED_WHY.map((w) => <li key={w}>{w}</li>)}</ul>
        </div>)}
    </details>
  );
}
