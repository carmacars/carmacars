// r48 speed (docs/changes/2026-11-20-r48-perf.md): the page's nonce put on every <script> while the HTML streams through,
// instead of after the whole page was read. The local server (scripts/serve.mjs) and the company's server
// (scripts/vps-server.mjs) used to hold the full page until its last byte, so a portal page showed nothing until every read
// was done; now the frame and the loading skeleton (loading.tsx) reach the browser first and the rest follows.
// Plain TypeScript with no imports: the two .mjs servers load it as it is (Node 22.18 strips the types).

const SCRIPT = /<script(?=[\s>])/g;

/** Every <script> of a complete piece of HTML with the nonce (the same rule the servers used on the whole page). */
export function addNonce(html: string, nonce: string): string {
  return html.replace(SCRIPT, `<script nonce="${nonce}"`);
}

/** A rewriter for HTML that arrives in pieces: `push` returns what can be sent now, `end` the rest. A "<script" split
 *  between two pieces is held back until it is whole: the longest text that can match is "<script" plus the one character
 *  after it, so only a "<" in the last eight characters is ever held (none of those characters is a "<" again). */
export function nonceRewriter(nonce: string): { push(text: string): string; end(): string } {
  let carry = '';
  return {
    push(text: string) {
      const s = carry + text;
      const lt = s.lastIndexOf('<');
      const cut = lt >= 0 && s.length - lt <= 8 ? lt : s.length;
      carry = s.slice(cut);
      return addNonce(s.slice(0, cut), nonce);
    },
    end() {
      const s = carry;
      carry = '';
      return addNonce(s, nonce);
    }
  };
}
