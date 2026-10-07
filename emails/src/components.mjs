// Components. Each function returns a plain block object; src/layout.mjs turns blocks into HTML and plain text.
// Copy strings may contain merge variables ({{name}}), **bold**, and links written [label](@link_name) or
// [label]({{url_variable}}). @link_name is a key of PATHS in src/links.mjs.

export const hero = (eyebrow, title, lead) => ({ type: 'hero', eyebrow, title, lead });
export const p = (text) => ({ type: 'p', text });
export const small = (text) => ({ type: 'small', text });
export const h = (text) => ({ type: 'h', text });
export const rule = () => ({ type: 'rule' });

// Vehicle photo slot. Reads {{vehicle_image_url}} and {{vehicle_name}}; shows a dark block with the name when no photo.
export const vehicle = (caption) => ({ type: 'vehicle', caption });

// Two large facts side by side, for example pickup and return. items: [{ label, value, sub }]
export const keyfacts = (...items) => ({ type: 'keyfacts', items });

// One large figure, for example a total or a refund. Set in red.
export const figure = (label, value, sub) => ({ type: 'figure', label, value, sub });

// Detail table: rows of [label, value] or { label, value, when: 'variable' } for an optional row.
export const facts = (...rows) => ({ type: 'facts', rows: rows.map(row) });

// Price breakdown. opts: { each: 'line_items' (items carry label and amount), rows: [[label, amount]],
// total: [label, amount], after: [[label, amount]] }
export const price = (opts) => ({ type: 'price', ...opts, rows: (opts.rows || []).map(row), after: (opts.after || []).map(row) });

// Before and after table for adjustments. Reads a list variable whose items carry label, before, after.
export const compare = (each, beforeHead = 'You asked for', afterHead = 'Our offer') => ({ type: 'compare', each, beforeHead, afterHead });

// Generic table. cols: [{ head, value, align: 'left'|'right', strong }]; each: list variable; foot: [[label, amount]]
export const table = (opts) => ({ type: 'table', ...opts });

// Linked rows, for digests and job lists. Items carry the fields named in title, meta and href.
export const rows = (each, title, meta, href) => ({ type: 'rows', each, title, meta, href });

export const button = (label, href) => ({ type: 'button', label, href });
export const link = (label, href) => ({ type: 'link', label, href });

// Notice box. tone: 'alert' (red rule) or 'info' (black rule).
export const notice = (tone, title, text) => ({ type: 'notice', tone, title, text });

export const list = (...items) => ({ type: 'list', items });
// Numbered steps. items: [title, text] pairs.
export const steps = (...items) => ({ type: 'steps', items });

// Optional section and loop.
export const when = (name, then, otherwise = []) => ({ type: 'when', name, then: [].concat(then), otherwise: [].concat(otherwise) });
export const each = (name, blocks) => ({ type: 'each', name, blocks: [].concat(blocks) });

function row(r) {
  return Array.isArray(r) ? { label: r[0], value: r[1], when: r[2] } : r;
}
