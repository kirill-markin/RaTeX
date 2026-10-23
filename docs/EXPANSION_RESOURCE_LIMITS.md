# Macro expansion allocation limits

RaTeX rejects excessive macro-generated allocations with a `ParseError`
containing `Macro expansion resource limit exceeded`. Limits are shared by one
`MacroExpander` (and therefore by one normal `parse` call), including all macro
definitions, groups, nested expansion, Braket helpers and mhchem handlers.

## Defaults and accounting

| Resource | Cumulative default |
| --- | ---: |
| Newly constructed/copied expansion tokens | 100,000 |
| Dynamic text constructed/copied by controlled builders (UTF-8 bytes) | 8 MiB |
| mhchem `Value` nodes plus object member slots | 100,000 |

The existing 1,000 macro-call limit and shared depth-32 policy also apply. A
one-token self-recursive macro normally reaches the call limit first; a macro
that repeatedly copies a large body reaches the allocation limit first.

Reservations use checked arithmetic and check all requested dimensions before
changing any counter or constructing output. A failed reservation leaves the
counters unchanged. Earlier successful reservations are not refunded when a
parse fails, temporary data is dropped, or a definition is replaced. Errors
include the rejection site, used/requested/limit values, and macro-call count.
`requested=None` denotes arithmetic overflow. These diagnostics do not include
copies of the offending source text.

A newly copied token consumes one token unit and its text length in bytes.
Building an intermediate string and then copying that text into tokens consumes
bytes at both construction sites. Moving existing strings/tokens/vectors,
reversing a vector, collecting expanded tokens, and cloning an `Arc` consume no
additional allowance. Vector capacity, allocator metadata and parser AST
storage are not measured by these counters.

Token macro parameter replacement walks the template in logical order. Each
parameter's last occurrence takes ownership of its tokens; preceding
occurrences clone them. Template literals are copied from the immutable macro
definition, while placeholder tokens are not copied. For example, replacing
`#1#1` with owned argument `ab` adds exactly two tokens and two bytes, producing
`abab`. `##` creates one literal `#` when argument substitution is active,
retaining the second token's source location and flags. The location preserves
mhchem's source-gap-based whitespace reconstruction.

## Implementation boundaries

The change is divided into two independently validated layers:

1. Macro expansion: immutable `Arc`-backed namespace definitions and undo
   records; a once-initialized shared builtin table with parse-local overrides;
   borrowed Text-template scanning; prechecked token copying and
   parameter substitution; ownership-preserving argument/branch selection;
   checked Braket replacement and generated-text tokenization.
2. mhchem: the same budget flows through argument rebuilding, normalization,
   buffer/actions, JSON construction and texify. Pattern captures and remaining
   input borrow the normalized input wherever possible. Combined captures use
   checked string construction. Owned JSON children are moved into checked
   containers rather than serialized/deep-copied through `json!`.

`ratex_lexer::Lexer::next_span()` and `ratex_lexer::TokenSpan` are additive public
APIs. A span borrows token text (or normalized static whitespace), carries its
source location and an explicit EOF flag. `into_token()` allocates the text;
resource-aware callers check first. Existing `Lexer::lex()` behavior and all
existing parser, macro-definition, mhchem, render, ABI and DisplayList JSON
signatures remain unchanged. No public budget configuration is introduced.

## Scope of the guarantee

These are cumulative allocation limits on controlled expansion/generation
paths, not a process RSS cap and not a complete CPU-work limit. Direct source
lexing, source-sized argument storage, bounded diagnostic/position copies,
parser lookahead copies, renderer allocations and allocator overhead are not
charged as generated output. In particular, a long `\verb` directly in source
is different from a long token created by a Text macro: only the latter is
checked against this budget before its string is allocated.

Externally registered Rust function handlers are trusted code: allocations
inside an arbitrary callback cannot be constrained by the parser. Host input
size and execution-time policies remain separate. Repeated scanning and regex
work can consume CPU without exhausting the allocation budget. This change
must not be described as resolving every memory- or CPU-based denial of service.

## Verification

Unit tests exercise exact token/byte/node boundaries, overflow and atomic
failure, UTF-8 byte lengths, shared aliases and group restoration, moved
parameters, macro-generated long tokens, nested budgets, Braket intermediate
copies, and mhchem structure/texify rejection.

`cargo test -p ratex-parser --test expansion_allocations --release -- --nocapture`
runs attack inputs in separate child processes with a 30-second timeout and
counts live requested allocation bytes during parsing after lazy-data warmup.
Its 64 MiB incremental-peak ceiling is a regression-test guard for those inputs,
not a universal memory guarantee. The original reports also have direct parser
regressions, including their original macro names and alphabetic variants.

The isolated tests use the public `parse` entry point with unchanged default
budgets. They also pin the amendment's 21-byte `\bmod`, 79-byte `\&`, and
143-byte `\\` recursive inputs, plus an approximately 1 KiB variant of each.
The small inputs currently reach the macro-call limit first; the larger
variants must reach the resource limit. Every case checks its source byte
length, expected rejection and the same 64 MiB incremental-peak ceiling. The
internal 500-token unit tests remain separate checks of accounting behavior;
they do not establish the default-budget memory bound.

Run the corpus compatibility capture described in `CORE_INTERNALS.md` before
and after changes, and the render-bench skill's release benchmarks. Limits must
not be silently raised to make a failing test or normal formula pass: first
investigate duplicated accounting, unnecessary copies, or changed semantics.

## Validation record (2026-10-10)

Baseline: repository commit `776c1d3`, same Darwin x86_64 host, Rust 1.95.0,
release builds. Three corpus captures contain 1,075 main formulas, 103 mhchem
formulas and 38 prooftrees. AST, unrounded layout, DisplayList and PNG comparisons
are exact, including the main suite's one existing unsupported case. The
Python comparator reports zero per-case score regressions for all three suites.
Generated captures and reports are local under `target/expansion-compat/`;
reference fixtures and the committed golden baseline are unchanged.

Process-isolated allocation measurements after lazy-data warmup:

| Input | Source bytes | Incremental peak requested bytes | Rejection |
| --- | ---: | ---: | --- |
| Original tenfold `\edef` report | 260 | 8,187,034 | token budget, call 39 |
| Original numbered doubling report | 354 | 5,764,225 | token budget, call 25 |
| Alphabetic doubling chain | 309 | 6,392,596 | token budget, call 26 |
| Repeated 2 KiB macro body | 2,060 | 24,611,691 | token budget, call 49 |
| Nested mhchem structure stress | 20,906 | 10,341,259 | structure budget, call 1 |

The mhchem stress reaches 100,000 structure units after 256,624 generated text
bytes. The smaller recursive compatibility tests deliberately use a smaller
internal allocation limit; a bare self-recursion still hits the original
macro-call limit. These values measure allocator requests within the test
window, not RSS, and should not be directly compared with the reports' RSS
figures as if they were the same metric.

A separate flat mhchem stress (`H + ` repeated 5,000 times inside `\ce`) exceeded
the 30-second test timeout before exhausting the allocation allowance on this
host. This confirms the CPU-safety limitation above; it is not counted as a
successful rejection. The committed structure stress uses many small nested
state machines to test the allocation limit without relying on that flat-input
regex behavior. CPU budgets/regex complexity remain separate follow-up work.

Five alternating before/after runs of the 100-formula release render benchmark
(warmup 1, measurement 3 iterations per formula per run) gave these medians:

| Stage | Before (µs/formula) | After (µs/formula) |
| --- | ---: | ---: |
| Parse + layout | 392 | 249 |
| PNG rendering | 357 | 415 |
| SVG text | 48 | 51 |
| SVG standalone | 465 | 555 |
| PDF | 1,224 | 1,358 |
| End-to-end parse/layout + PNG | 749 | 684 |

Parse/layout improved in every category (math: 208 → 69 µs; chemistry:
949 → 726 µs). Sharing immutable builtin definitions avoids rebuilding their
namespace for every parse; the first implementation that allocated new `Arc`s
for all builtins on every parse showed a simple-formula regression and was
replaced by the shared table.

The host exhibited substantial timing variance: per-run PNG means ranged from
344–1,067 µs before and 345–1,228 µs after. Renderer code and rendered bytes are
unchanged, so the individual renderer-stage medians above are not evidence of
a statistically established regression or speedup. End-to-end PNG was faster in
all five paired runs. Raw runs and aggregates are retained under
`target/expansion-compat/benchmarks/`; the measurements do not establish a
universal performance guarantee.

Native lexer/parser/layout tests, the isolated allocation test, strict Clippy,
format checking, and the Node/WASM error-propagation test passed. The WASM test
checks both a resource-limit error and a successful subsequent render, rather
than merely checking that the WASM target compiles.
