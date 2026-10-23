import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const loader = readFileSync(new URL("../public/katex-fonts-link.js", import.meta.url), "utf8");
const gallery = readFileSync(new URL("../public/gallery.js", import.meta.url), "utf8");
const flush = () => new Promise((resolve) => setImmediate(resolve));

function harness({ outcome, staticLink = false, fontLoad = () => Promise.resolve([{}]) } = {}) {
  const links = [];
  const timers = new Map();
  const status = { textContent: "" };
  let fontCalls = 0;
  let nextTimer = 0;
  let currentLink;
  class Link extends EventTarget {
    sheet = null;
    listeners = new Set();
    setAttribute() {}
    addEventListener(type, callback) {
      super.addEventListener(type, callback);
      this.listeners.add(callback);
    }
    removeEventListener(type, callback) {
      super.removeEventListener(type, callback);
      this.listeners.delete(callback);
    }
    remove() { if (currentLink === this) currentLink = null; }
    cloneNode() { return Object.assign(new Link(), { href: this.href }); }
    replaceWith(link) { this.remove(); insert(link); }
  }
  function insert(link) {
    currentLink = link;
    links.push(link);
    if (outcome) emit(outcome);
  }
  function emit(type) {
    if (type === "load") currentLink.sheet = {};
    currentLink.dispatchEvent(new Event(type));
  }
  const context = vm.createContext({
    URL, console,
    location: new URL("https://example.test/RaTeX/"),
    setTimeout(callback, delay) {
      assert.equal(delay, 15000);
      timers.set(++nextTimer, callback);
      return nextTimer;
    },
    clearTimeout(id) { timers.delete(id); },
    document: {
      readyState: "complete",
      head: { insertBefore: insert },
      createElement: () => new Link(),
      querySelector: () => currentLink,
      getElementById: (id) => id === "status" ? status : {},
      fonts: { load: (...args) => { fontCalls++; return fontLoad(...args); } },
    },
  });
  if (staticLink) {
    insert(Object.assign(new Link(), { href: "https://example.test/RaTeX/platforms/web/fonts.css" }));
  } else {
    vm.runInContext(loader, context);
  }
  // Deliberately evaluate after insertion and any synchronous load/error event.
  vm.runInContext(gallery, context);
  return {
    context, links, timers, status, emit,
    engine: () => context.RaTeXGallery.ensurePlaygroundEngine(),
    get fontCalls() { return fontCalls; },
    setFontLoad(load) { fontLoad = load; },
    async expire() {
      const callbacks = [...timers.values()];
      timers.clear();
      callbacks.forEach((callback) => callback());
      await flush();
    },
  };
}

async function assertFontsReady(promise) {
  const result = await promise;
  // This VM intentionally has no WASM import callback. Reaching this result
  // proves fonts completed and initialization advanced to the WASM stage.
  assert.equal(result.renderLatex, null);
  assert.ok(result.wasmError);
}

test("an early cached stylesheet success is retained", async () => {
  const h = harness({ outcome: "load" });
  const first = h.engine();
  assert.equal(h.engine(), first, "concurrent callers share initialization");
  await assertFontsReady(first);
  assert.equal(h.fontCalls, 19);
  assert.equal(h.timers.size, 0);
  assert.equal(h.links[0].listeners.size, 0);
  assert.notEqual(h.engine(), first, "failed WASM initialization can be retried");
  await flush();
});

test("an error before gallery startup rejects and a later attempt requests a new link", async () => {
  const h = harness({ outcome: "error" });
  const first = h.engine();
  await assert.rejects(first, /Failed to load the RaTeX font stylesheet/);
  assert.equal(h.fontCalls, 0);
  assert.equal(h.timers.size, 0);
  assert.equal(h.links[0].listeners.size, 0);
  // Retry still sees an immediate failure, rather than a stale pending promise.
  await assert.rejects(h.engine(), /Failed to load/);
  assert.equal(h.links.length, 2);
});

test("stylesheet failure can recover without reloading the page", async () => {
  const h = harness();
  const failed = assert.rejects(h.engine(), /Failed to load/);
  h.emit("error");
  await failed;
  const retry = h.engine();
  assert.equal(h.links.length, 2);
  h.emit("load");
  await assertFontsReady(retry);
  assert.equal(h.fontCalls, 19);
  assert.equal(h.timers.size, 0);
});

for (const staticLink of [false, true]) {
  test(`stalled ${staticLink ? "legacy static" : "injected"} stylesheet times out and retries`, async () => {
    const h = harness({ staticLink });
    const failed = assert.rejects(h.engine(), /Timed out loading/);
    await h.expire();
    await failed;
    assert.equal(h.links[0].listeners.size, 0);
    const retry = h.engine();
    assert.equal(h.links.length, 2);
    h.emit("load");
    await assertFontsReady(retry);
    assert.equal(h.timers.size, 0);
  });
}

for (const failure of ["reject", "missing", "timeout"]) {
  test(`font file ${failure} clears initialization and reloads the stylesheet on retry`, async () => {
    const h = harness({
      outcome: "load",
      fontLoad: () => failure === "reject" ? Promise.reject(new Error("font network failure"))
        : failure === "missing" ? Promise.resolve([]) : new Promise(() => {}),
    });
    const failed = assert.rejects(h.engine(), /font network failure|not registered|Timed out loading/);
    await flush();
    if (failure === "timeout") await h.expire();
    await failed;
    h.setFontLoad(() => Promise.resolve([{}]));
    await assertFontsReady(h.engine());
    assert.equal(h.links.length, 2);
    assert.equal(h.fontCalls, 38);
    assert.equal(h.timers.size, 0);
  });
}

test("gallery displays a font error instead of leaving Loading fonts on screen", async () => {
  const h = harness({ outcome: "error" });
  await h.context.RaTeXGallery.init({ statusEl: "status" });
  assert.match(h.status.textContent, /Failed to load fonts/);
  assert.equal(h.timers.size, 0);
});

test("hero releases its busy state after a font error and its Render button retries", async () => {
  const h = harness();
  class Element extends EventTarget {
    value = "x";
    dataset = {};
    attributes = {};
    classList = { add() {}, remove() {} };
    closest() { return { dataset: {}, querySelectorAll: () => [] }; }
    setAttribute(name, value) { this.attributes[name] = value; }
  }
  const elements = new Map();
  h.context.document.getElementById = (id) => {
    if (!elements.has(id)) elements.set(id, new Element());
    return elements.get(id);
  };
  h.context.window = h.context;
  const hero = readFileSync(new URL("../src/components/HeroPlayground.astro", import.meta.url), "utf8");
  const script = hero.match(/<script is:inline>([\s\S]*?)<\/script>/)[1];
  vm.runInContext(script, h.context);
  const button = elements.get("hero-playground-render");
  const output = elements.get("hero-playground-out");
  const error = elements.get("hero-playground-error");
  assert.equal(button.disabled, true);
  assert.equal(output.attributes["aria-busy"], "true");
  h.emit("error");
  await flush();
  assert.equal(button.disabled, false);
  assert.equal(output.attributes["aria-busy"], "false");
  assert.match(error.textContent, /Failed to load/);
  button.dispatchEvent(new Event("click"));
  assert.equal(button.disabled, true);
  assert.equal(h.links.length, 2);
  h.emit("load");
  await flush();
  assert.equal(h.fontCalls, 19);
  // WASM is unavailable in this VM, but even that failure releases the UI.
  assert.equal(button.disabled, false);
  assert.equal(output.attributes["aria-busy"], "false");
});

test("both localized home pages inherit the event-recording loader", () => {
  const home = readFileSync(new URL("../src/pages/index.astro", import.meta.url), "utf8");
  const zh = readFileSync(new URL("../src/pages/zh/index.astro", import.meta.url), "utf8");
  assert.match(home, /<script slot="head" src=\{`\$\{base\}katex-fonts-link\.js`\}/);
  assert.doesNotMatch(home, /<link[^>]*data-ratex-fonts-stylesheet/s);
  assert.match(zh, /index\.astro/);
});
