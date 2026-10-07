// CarmaCars email template engine. No dependencies. The application can import this file as is.
//
// Syntax (the whole of it):
//   {{name}}                         a value. HTML-escaped when rendering HTML, raw in plain text.
//   {{#if name}} A {{else}} B {{/if}} optional section. {{else}} is optional.
//                                     False when the value is missing, "", false, 0, null or an empty list.
//   {{#each name}} ... {{/each}}      repeat for each object in a list. Inside, {{field}} reads the item first,
//                                     then the values outside the loop.
// Names are lower-case letters, digits and underscores. Sections can be nested.
// A section tag that sits alone on its line does not leave a blank line behind.

const TAG = /\{\{\s*(#if|#each|\/if|\/each|else)?\s*([a-z0-9_]*)\s*\}\}/g;

export function escapeHtml(v) {
  return String(v).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

export function parse(src) {
  // Standalone section tags: drop the line break they would leave behind.
  src = src.replace(/^[ \t]*(\{\{\s*(?:#if|#each)\s+[a-z0-9_]+\s*\}\}|\{\{\s*(?:\/if|\/each|else)\s*\}\})[ \t]*\r?\n/gm, '$1');
  const root = { type: 'root', body: [] };
  const stack = [root];
  let target = root.body;
  let last = 0;
  let m;
  TAG.lastIndex = 0;
  while ((m = TAG.exec(src))) {
    if (m.index > last) target.push({ type: 'text', value: src.slice(last, m.index) });
    last = TAG.lastIndex;
    const [, kind, name] = m;
    const top = stack[stack.length - 1];
    if (!kind) {
      if (!name) throw new Error('Empty tag at ' + m.index);
      target.push({ type: 'var', name });
    } else if (kind === '#if' || kind === '#each') {
      if (!name) throw new Error(kind + ' needs a name');
      const node = { type: kind.slice(1), name, body: [], otherwise: [] };
      target.push(node);
      stack.push(node);
      target = node.body;
    } else if (kind === 'else') {
      if (top.type !== 'if') throw new Error('{{else}} outside {{#if}}');
      target = top.otherwise;
    } else {
      const want = kind.slice(1);
      if (top.type !== want) throw new Error('Unexpected {{' + kind + '}}');
      stack.pop();
      const parent = stack[stack.length - 1];
      target = parent.type === 'root' ? parent.body : (parent.inElse ? parent.otherwise : parent.body);
    }
    if (kind === 'else') top.inElse = true;
  }
  if (stack.length > 1) throw new Error('Unclosed {{#' + stack[stack.length - 1].type + ' ' + stack[stack.length - 1].name + '}}');
  if (last < src.length) target.push({ type: 'text', value: src.slice(last) });
  return root.body;
}

function lookup(scopes, name) {
  for (let i = scopes.length - 1; i >= 0; i--) {
    if (scopes[i] != null && Object.prototype.hasOwnProperty.call(scopes[i], name)) return scopes[i][name];
  }
  return undefined;
}

function truthy(v) {
  return Array.isArray(v) ? v.length > 0 : Boolean(v);
}

// render(template, values, { html: true|false, strict: true|false })
// strict: throw when a value is missing, so a half-filled email is never sent.
export function render(src, values, opts = {}) {
  const { html = true, strict = true } = opts;
  const walk = (nodes, scopes) => {
    let out = '';
    for (const n of nodes) {
      if (n.type === 'text') out += n.value;
      else if (n.type === 'var') {
        const v = lookup(scopes, n.name);
        if (v === undefined || v === null) {
          if (strict) throw new Error('Missing value: ' + n.name);
          continue;
        }
        out += html ? escapeHtml(v) : String(v);
      } else if (n.type === 'if') {
        const v = lookup(scopes, n.name);
        if (v === undefined && strict) throw new Error('Missing value: ' + n.name);
        out += walk(truthy(v) ? n.body : n.otherwise, scopes);
      } else if (n.type === 'each') {
        const v = lookup(scopes, n.name);
        if (!Array.isArray(v)) {
          if (strict) throw new Error('Not a list: ' + n.name);
          continue;
        }
        for (const item of v) out += walk(n.body, scopes.concat([item]));
      }
    }
    return out;
  };
  return walk(parse(src), [values]);
}

// Names a template reads from the top level, given sample values (used to tell item fields from outer values).
export function usedNames(src, sample) {
  const used = new Set();
  const walk = (nodes, scopes) => {
    for (const n of nodes) {
      if (n.type === 'text') continue;
      const inItem = scopes.slice(1).some((s) => s && Object.prototype.hasOwnProperty.call(s, n.name));
      if (!inItem) used.add(n.name);
      if (n.type === 'if') { walk(n.body, scopes); walk(n.otherwise, scopes); }
      if (n.type === 'each') {
        const list = lookup(scopes, n.name);
        const first = Array.isArray(list) && list.length ? Object.assign({}, ...list) : {};
        walk(n.body, scopes.concat([first]));
      }
    }
  };
  walk(parse(src), [sample]);
  return used;
}

// Plain-text render: same as render with html off, then tidy the blank lines optional sections leave.
export function renderText(src, values, opts = {}) {
  return render(src, values, { ...opts, html: false }).replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n');
}
