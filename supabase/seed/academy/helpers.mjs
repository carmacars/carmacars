// Small builders for the academy content (supabase/seed/0208_gen_academy.mjs). A scene: what the screen says (caption), what
// the voice says (say), and the picture (visual). A question: the prompt, the options, the index of the right one, why.
export const S = (caption, say, visual) => ({ caption, say, visual });
export const title = (heading, text = '') => ({ kind: 'title', heading, text });
export const chat = (...lines) => ({ kind: 'chat', lines: lines.map(([who, text]) => ({ who, text })) });
export const list = (heading, items) => ({ kind: 'list', heading, items });
export const steps = (heading, items) => ({ kind: 'steps', heading, items });
export const money = (heading, rows, total) => ({ kind: 'money', heading, rows, ...(total ? { total } : {}) });
export const rule = (heading, text, tone = 'ok') => ({ kind: 'rule', heading, text, tone });
export const Q = (prompt, options, answer, explain) => ({ prompt, options, answer, explain });
export const L = (title, ...scenes) => ({ title, scenes });
