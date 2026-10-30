// A minimal, honest browser shim: enough for the prototype's own inline script
// to load and for `tick()` to run its real arithmetic, and nothing more.
//
// It does NOT reimplement any of the prototype's logic. Every DOM touch point is
// inert: style writes are recorded but never read back by the maths, and
// `querySelectorAll` returns the empty list, so any code path that *depends* on
// a real DOM (scanUpd's dot loop, glUpd's three.js renderer) simply does nothing
// instead of producing a fake answer.
//
// If a check ever needs a value the shim cannot supply, the right fix is to
// record it as a limitation, not to make the shim smarter.

const mkStyle = () =>
  new Proxy(
    {},
    {
      get(t, k) {
        if (k === 'setProperty') return () => {};
        return k in t ? t[k] : '';
      },
      set(t, k, v) {
        t[k] = v;
        return true;
      },
    },
  );

function makeNode(tag = 'div', id = '') {
  const node = {
    tagName: String(tag).toUpperCase(),
    id,
    style: mkStyle(),
    dataset: {},
    classList: {
      _s: new Set(),
      add(...c) {
        c.forEach((x) => this._s.add(x));
      },
      remove(...c) {
        c.forEach((x) => this._s.delete(x));
      },
      toggle(c) {
        this._s.has(c) ? this._s.delete(c) : this._s.add(c);
      },
      contains(c) {
        return this._s.has(c);
      },
    },
    children: [],
    childNodes: [],
    isConnected: false,
    value: undefined,
    textContent: '',
    innerHTML: '',
    checked: false,
    width: 0,
    height: 0,
    setAttribute(k, v) {
      node['attr_' + k] = v;
    },
    getAttribute(k) {
      return node['attr_' + k];
    },
    removeAttribute(k) {
      delete node['attr_' + k];
    },
    appendChild(c) {
      node.children.push(c);
      return c;
    },
    removeChild(c) {
      return c;
    },
    addEventListener() {},
    removeEventListener() {},
    setPointerCapture() {},
    releasePointerCapture() {},
    closest() {
      return null;
    },
    querySelector(sel) {
      return makeNode('div', '');
    },
    // Deliberately empty: no code path may *depend* on finding real elements.
    querySelectorAll() {
      return [];
    },
    getContext() {
      return null;
    },
    getBoundingClientRect() {
      return { left: 0, top: 0, width: 0, height: 0, right: 0, bottom: 0 };
    },
    focus() {},
    blur() {},
    click() {},
  };
  return node;
}

/**
 * Installs `document` and `window` on the global object. Nothing else: an audit
 * of the four sources (`grep -o '\bnavigator\b' …` etc.) shows they touch only
 * `document` and `window` — `THREE` is referenced but always from inside a
 * `try { … } catch { GLX.ok = false }`, so an undefined `THREE` is the correct
 * Node behaviour, not something to fake.
 *
 * `inputDefaults` maps element id -> the `value="..."` the HTML actually ships
 * with, so a planner's "default" is the prototype's default and not a guess.
 */
export function installDom({ inputDefaults = {} } = {}) {
  const prev = new Map();
  const set = (k, v) => {
    prev.set(k, Object.getOwnPropertyDescriptor(globalThis, k));
    Object.defineProperty(globalThis, k, {
      value: v,
      writable: true,
      configurable: true,
      enumerable: true,
    });
  };

  const cache = new Map();
  const byId = (id) => {
    if (!cache.has(id)) {
      const n = makeNode('div', id);
      if (Object.prototype.hasOwnProperty.call(inputDefaults, id)) {
        n.value = inputDefaults[id];
      }
      cache.set(id, n);
    }
    return cache.get(id);
  };

  const doc = {
    readyState: 'complete',
    documentElement: makeNode('html'),
    body: makeNode('body'),
    head: makeNode('head'),
    getElementById: (id) => byId(id),
    querySelector: (sel) => {
      const m = /^#([\w-]+)$/.exec(String(sel));
      return m ? byId(m[1]) : makeNode('div', '');
    },
    querySelectorAll: () => [],
    createElement: (t) => makeNode(t),
    createElementNS: (_ns, t) => makeNode(t),
    addEventListener() {},
    removeEventListener() {},
  };

  set('document', doc);
  set('window', globalThis);

  return {
    byId,
    /** Elements the shim handed out, for assertions about what was touched. */
    cache,
    uninstall() {
      for (const [k, d] of prev) {
        if (d) Object.defineProperty(globalThis, k, d);
        else delete globalThis[k];
      }
    },
  };
}
