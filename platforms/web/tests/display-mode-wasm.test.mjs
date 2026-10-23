import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import * as ratex from "../dist/index.js";
import initWasm, * as wasmModule from "../pkg/ratex_wasm.js";

let wasmInitPromise;

function initGeneratedWasm() {
  if (!wasmInitPromise) {
    const wasmUrl = new URL("../pkg/ratex_wasm_bg.wasm", import.meta.url);
    wasmInitPromise = readFile(wasmUrl).then((moduleBytes) =>
      initWasm({ module_or_path: moduleBytes })
    );
  }
  return wasmInitPromise;
}

function assertJsErrorInsteadOfWasmTrap(callback, pattern) {
  assert.throws(callback, (error) => {
    assert.equal(error instanceof WebAssembly.RuntimeError, false);
    assert.match(String(error), pattern);
    return true;
  });
}

test("the generated WASM honors displayMode through every public API", async () => {
  await initGeneratedWasm();

  const latex = "\\frac{1}{2}";
  const defaultDisplay = wasmModule.renderLatex(latex);
  const explicitDisplay = wasmModule.renderLatex(latex, undefined, true);
  const positionalInline = wasmModule.renderLatex(latex, undefined, false);
  const optionsInline = wasmModule.renderLatexWithOptions(latex, {
    displayMode: false,
  });

  assert.equal(defaultDisplay, explicitDisplay);
  assert.notEqual(explicitDisplay, positionalInline);
  assert.equal(positionalInline, optionsInline);

  const displayList = JSON.parse(explicitDisplay);
  const inlineList = JSON.parse(positionalInline);
  assert.ok(inlineList.height < displayList.height);
  assert.ok(inlineList.depth < displayList.depth);

  await ratex.initRatex(async () => wasmModule);
  assert.equal(ratex.renderLatex(latex, { displayMode: false }), positionalInline);
  assert.equal(
    ratex.renderLatex(latex, undefined, false),
    positionalInline
  );
});

test("over-nested input returns a JS error instead of trapping WASM", async () => {
  await initGeneratedWasm();

  const overNested = `${"\\sqrt{".repeat(300)}x${"}".repeat(300)}`;
  assert.throws(
    () => wasmModule.renderLatex(overNested),
    /Recursion limit exceeded/
  );
});

test("flat delimiter chains return JS errors instead of trapping WASM", async () => {
  await initGeneratedWasm();

  for (const command of ["\\bigl", "\\left"]) {
    const input = `${command.repeat(4_200)}(`;
    assertJsErrorInsteadOfWasmTrap(
      () => wasmModule.renderLatex(input),
      /Expected (?:group|delimiter)|Invalid delimiter/
    );
  }
});

test("slashed accepts the depth boundary and rejects deeper input without a WASM trap", async () => {
  await initGeneratedWasm();
  const nested = (depth) => `${"\\slashed{".repeat(depth)}p${"}".repeat(depth)}`;
  assert.doesNotThrow(() => JSON.parse(wasmModule.renderLatex(nested(32))));
  for (const input of [nested(33), nested(300)]) {
    assertJsErrorInsteadOfWasmTrap(
      () => wasmModule.renderLatex(input),
      /Recursion limit exceeded/
    );
  }
  assertJsErrorInsteadOfWasmTrap(
    () => wasmModule.renderLatex(`${"\\slashed".repeat(300)}p`),
    /Unexpected end of input|Recursion limit exceeded/
  );
});

test("centernot accepts the depth boundary and rejects deeper input without a WASM trap", async () => {
  await initGeneratedWasm();
  const nested = (depth) => `${"\\centernot{".repeat(depth)}p${"}".repeat(depth)}`;
  assert.doesNotThrow(() => JSON.parse(wasmModule.renderLatex(nested(32))));
  for (const input of [nested(33), nested(300)]) {
    assertJsErrorInsteadOfWasmTrap(
      () => wasmModule.renderLatex(input),
      /Recursion limit exceeded/
    );
  }
  assertJsErrorInsteadOfWasmTrap(
    () => wasmModule.renderLatex(`${"\\centernot".repeat(300)}p`),
    /Unexpected end of input|Recursion limit exceeded/
  );
});

test("many consecutive comments stay flat through the WASM pipeline", async () => {
  await initGeneratedWasm();

  const rendered = wasmModule.renderLatex(`${"%\n".repeat(4_200)}x`);
  assert.doesNotThrow(() => JSON.parse(rendered));
});

test("deep explicit array tags return a JS recursion error", async () => {
  await initGeneratedWasm();

  let tag = "x";
  for (let i = 0; i < 12; i += 1) {
    tag = `\\raisebox{0pt}{${tag}}`;
  }

  for (const [environment, body] of [
    ["equation", "x"],
    ["align", "x &= y"],
  ]) {
    const input = `\\begin{${environment}}${body}\\tag{${tag}}\\end{${environment}}`;
    assertJsErrorInsteadOfWasmTrap(
      () => wasmModule.renderLatex(input),
      /Recursion limit exceeded/
    );
  }
});

test("layout amplification returns a JS error and bounded middle nesting renders", async () => {
  await initGeneratedWasm();
  const excessiveBold = `${"\\pmb{".repeat(16)}x${"}".repeat(16)}`;
  assertJsErrorInsteadOfWasmTrap(
    () => wasmModule.renderLatex(excessiveBold),
    /Layout resource limit exceeded/
  );
  const middle = `${"\\left(".repeat(32)}x${"\\middle|x\\right)".repeat(32)}`;
  assert.ok(JSON.parse(wasmModule.renderLatex(middle)).items.length > 0);
  assert.ok(JSON.parse(wasmModule.renderLatex("x+1")).items.length > 0);
});

test("array rules count toward the expanded layout budget", async () => {
  await initGeneratedWasm();
  for (const rule of ["\\hline ", "\\hdashline "]) {
    const formula = (count) =>
      `${"\\pmb{".repeat(13)}\\begin{array}{c}${rule.repeat(count)}x\\end{array}${"}".repeat(13)}`;
    assert.equal(
      JSON.parse(wasmModule.renderLatex(formula(3))).items.length,
      4 * 2 ** 13
    );
    for (const count of [4, 64, 300]) {
      assertJsErrorInsteadOfWasmTrap(
        () => wasmModule.renderLatex(formula(count)),
        /Layout resource limit exceeded/
      );
    }
  }
  assert.ok(JSON.parse(wasmModule.renderLatex("x+1")).items.length > 0);
});

test("vertical dashed separators are rejected by the layout budget", async () => {
  await initGeneratedWasm();
  const formula = (height, columns = ":c", layers = 13) =>
    `${"\\pmb{".repeat(layers)}\\begin{array}{${columns}}\\rule{1em}{${height}em}\\end{array}${"}".repeat(layers)}`;
  const boundary = formula("1.6");
  assert.equal(JSON.parse(wasmModule.renderLatex(boundary)).items.length, 65536);
  for (const input of [
    boundary + "x",
    formula("10", ":c:"),
    formula("1000", ":c:"),
    formula("1000000000", ":c", 0),
  ]) {
    assertJsErrorInsteadOfWasmTrap(
      () => wasmModule.renderLatex(input),
      /Layout resource limit exceeded/
    );
  }
  assert.ok(JSON.parse(wasmModule.renderLatex("x+1")).items.length > 0);
});

test("padded Array/CD grids share the layout budget and return JS errors", async () => {
  await initGeneratedWasm();
  for (const [cd, n, work] of [
    [false, 254, 65278],
    [true, 181, 65522],
  ]) {
    const sparse = (size) =>
      cd
        ? `\\begin{CD}${"@.".repeat(size)}${"\\\\x".repeat(size - 1)}\\end{CD}`
        : `\\begin{matrix}${"&".repeat(size - 1)}x${"\\\\x".repeat(size - 1)}\\end{matrix}`;
    const boundary = sparse(n) + "x".repeat(65536 - work);
    const display = JSON.parse(wasmModule.renderLatex(boundary));
    assert.equal(display.items.length, (cd ? n - 1 : n) + 65536 - work);
    const bold = (layers) =>
      `${"\\pmb{".repeat(layers)}${sparse(2)}${"}".repeat(layers)}`;
    assert.ok(JSON.parse(wasmModule.renderLatex(bold(12))).items.length > 0);
    for (const input of [
      boundary + "x",
      sparse(n + 1),
      sparse(500),
      bold(13),
      sparse(150).repeat(3),
    ]) {
      assertJsErrorInsteadOfWasmTrap(
        () => wasmModule.renderLatex(input),
        /Layout resource limit exceeded/
      );
      assert.ok(JSON.parse(wasmModule.renderLatex("x+1")).items.length > 0);
    }
  }
});
