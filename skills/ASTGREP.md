---
description: Structural code search and bulk rewrite with ast-grep. Use for mechanical multi-site refactors (signature changes, renames of calls, argument reordering) and for structural queries that grep gets wrong. Not for general exploration or type-aware questions.
---

# ast-grep

Binary is `ast-grep`. Do not use `sg`: on Linux it resolves to the unrelated `/usr/bin/sg` (shadow-utils) unless the npm bin dir is first on PATH.

Check it is installed with `command -v ast-grep`. If missing, tell the user instead of working around it with sed or scripts.

## When to use it

- Same structural change at many sites: use one rewrite instead of many Edit calls.
- Structural queries: "calls to `f` with two arguments", "`if` without `else`", matches that must ignore comments and strings.

Skip it for plain text lookups (use Grep), single edits (use Edit), and anything needing types or cross-file resolution (use the compiler or an LSP).

## Core usage

```
ast-grep run -p 'PATTERN' -l LANG [PATHS...]               # search
ast-grep run -p 'PATTERN' -r 'REWRITE' -l LANG [PATHS...]  # preview rewrite as a diff
ast-grep run -p 'PATTERN' -r 'REWRITE' -l LANG -U [PATHS]  # apply to files
```

- `-l` examples: `c`, `cpp`, `python`, `rust`, `ts`, `tsx`, `go`, `java`, `json`.
- Add `--json` (or `--json=stream`) when the output is parsed rather than read.
- `--globs '!build/**'` limits files. Without PATHS it searches the current directory.
- Always run the preview first and read the diff. Apply with `-U` only after that, on a clean or committed tree so `git diff` shows exactly what changed.

## Pattern syntax

A pattern is real code in the target language, with meta variables:

```
$X       one AST node            console.log($X)
$$$ARGS  zero or more nodes      foo($$$ARGS)
$_       one node, not captured  foo($_, $_)
```

- A repeated name must match the same code: `$A == $A`.
- The pattern must parse as valid code on its own. Use `--debug-query=ast` to see how a pattern or a file parses when a match is missing.
- Rewrite reuses the captured variables: `-p 'foo($A, $B)' -r 'foo($B, $A)'`.

### C: a bare call pattern does not work (verified)

`-p 'foo($$$A)'` parses at top level as a `macro_type_specifier` and silently matches nothing. Adding `;` makes it an expression statement, which only matches calls used as a whole statement, so `result = foo(x);` is missed. `--selector call_expression` on the CLI fails ("matches no node in the context").

Use a rule with `context` (code that parses) and `selector` (the node to match). Run it with `ast-grep scan -r rule.yml PATHS` or `--inline-rules`:

```
id: calls-foo
language: c
rule:
  pattern:
    context: 'void f(void) { foo($$$A); }'
    selector: call_expression
```

For rewrites, put `fix: 'bar($$$A)'` in the rule and use `scan -r rule.yml` (add `-U` to apply). Check how the equivalent works for `run -r` before relying on it.

### Rule relations

- `has` / `inside` search descendants / ancestors only with `stopBy: end`. The default stops at the first level.
- `precedes` / `follows` relate siblings only. A `return` nested in an `if` is not a sibling of a call before the `if`. Express "early return" as `inside: { kind: if_statement, stopBy: { kind: function_definition } }`.
- "Function does X but not Y": `kind: function_definition`, `has: {stopBy: end, pattern: X}`, `not: {has: {stopBy: end, pattern: Y}}`.

## Rules for complex cases

For conditions (inside, has, not, regex on a captured node) use a YAML rule:

```
ast-grep scan --inline-rules '
id: example
language: c
rule:
  pattern: foo($$$ARGS)
  not:
    inside:
      kind: comment
' [PATHS]
```

Put reusable rules in a file and run `ast-grep scan -r rule.yml`.

## Validate before trusting a result

A rule that matches nothing looks the same as a broken rule. Always:

1. Cross-check counts against grep on the same pattern, for example `grep -rE 'name\s*\(' --include='*.c' . | wc -l` against the ast-grep match count. They should agree for plain calls.
2. For a "0 results" audit, run the rule on a small synthetic file that contains one positive and one negative case, and confirm it reports exactly the positive.
3. Parse JSON with `python3 -I -c` (the working directory may contain `json.py`-style files).

## Caveats

- C and C++ with heavy preprocessor use: tree-sitter can mis-parse `#ifdef` blocks that split statements and macros that expand to syntax. Matches may be missed or misplaced. In `/workspace/external/fossa_cubeTools` a call-count check matched grep exactly (459 calls, 28 files), so plain calls are reliable there. Still compare counts before a large rewrite.
- A rewrite is syntactic. Review the diff and build or run the tests afterwards.
- Files in unsupported languages are skipped silently.
