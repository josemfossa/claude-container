---
name: stm32cube-local-devenv
description: Set up a local, uncommitted Linux dev environment for an STM32CubeIDE (Eclipse CDT) firmware project - containerised ARM toolchain build via just, host-side editor with clangd, headless CubeIDE regeneration, and a drift check against a CI Makefile. Use when the user has a CubeIDE project and wants to build/edit on Linux without adding files to the repo.
---

# Local dev environment for an STM32CubeIDE project

Goal: build and edit a CubeIDE project comfortably on Linux **without committing
anything**. All tooling lives in an untracked sidecar directory; the repo is not
modified. Optionally, use headless CubeIDE to detect when a hand-maintained CI
Makefile has drifted from the IDE's real build.

Work with the user: they often run podman/CubeIDE on the host while you run in a
sandbox without them. You cannot execute podman, just or CubeIDE yourself, so
write the files, say plainly what is untested, and iterate on pasted output.
Do not commit; the user commits.

## 1. Investigate first (read-only)

- How is it built today? Look for a CI workflow, a Makefile and source lists
  (often `.github/build/`), `.cproject`, `.project`, `.ioc`, linker scripts.
- Is the CI Makefile hand-written or generated? Check `git log` for it.
  Typically it is a hand-maintained mirror of the IDE build with an explicit
  source list: a file added in the IDE is silently missing from CI.
- Which tools exist on this machine (`podman`, `just`, `arm-none-eabi-gcc`,
  `clangd`, `bear`, `make`)? Report what is missing.
- Look for an existing `compile_commands.json` (usually stale, with the original
  developer's absolute paths) and check how it is ignored.
- CubeIDE leaves generated makefiles in `<app>/Debug/` (`makefile`,
  `sources.mk`, `*/subdir.mk`) after a build. They hold the exact source list
  and compiler flags but have absolute paths and are normally gitignored.

Use the repo's own CI Makefile as the single build definition. Do not write a
second one, and do not parse `.cproject`.

## 2. Keep local files out of the repo, and safe

Create the sidecar as a **nested git repo** inside the working tree, e.g.
`<repo>/.devenv/`, that the user versions separately (private remote). Symlink
the files tools need into the repo root, and hide everything via
`.git/info/exclude` (per clone, never committed; do not touch `.gitignore`).

- Why: `checkout`/`pull` never touch untracked files, and `git clean -fdx` skips
  nested repos (needs `-ff`) and would only delete the symlinks.
- Put the symlink and exclude creation in an idempotent `install.sh` inside the
  sidecar so a fresh clone is restored with one command. The exclude entries
  live in `.git/` and are lost if the clone is deleted; `install.sh` re-adds them.
- Sidecar `.gitignore`: temp files (and a legacy in-sidecar toolchain copy if
  one exists).
- Tell the user to commit the sidecar themselves.

Contents: container image file, `justfile`, a drift-check script, `.clangd`,
Helix config dir, one editorconfig file, `clang-format/` profiles, `install.sh`.

Gotcha: `sed -i` (and most "in-place" editors) on a symlink replaces it with a
regular file, so the edit never reaches the sidecar. Edit `<repo>/.devenv/<file>`
directly, or `ls -l` the target first.

## 3. Containerised build (podman + just)

- Image: Ubuntu LTS matching CI, the **same ARM GNU toolchain release as CI**
  (download the official tarball in a separate stage, copy it in), plus `make`
  and `bear`. No editor in it if the user edits on the host.
- Tag the image with the toolchain version (`<name>:<version>`). A bare tag is
  global per user: rebuilding it for another release silently changes every
  checkout and project that uses it. Containers are per-command (`--rm`) and not
  shared; only the read-only image is. Old image tags are not removed
  automatically (`podman images`, `podman image rm`; avoid `system prune -a`).
- Define the toolchain version **once**, as a `just` variable, and pass it to the
  image build with `--build-arg` (the Dockerfile default is only a fallback).
- Build recipe: run the existing CI Makefile in a throwaway
  `podman run --rm` with `--cap-drop=all --security-opt=no-new-privileges`,
  mounting the repo **at the same absolute path as on the host** (so paths in
  `compile_commands.json` are valid for the host editor). Only the app the user
  needs is built. Pass extra args (e.g. version defines) through to make.
- Running as root in rootless podman maps to the host uid, so output files are
  owned by the user. If permission problems appear, add `--userns=keep-id`.
- Other recipes: clean, shell, and `toolchain` (copy `/opt/<toolchain>` out of
  the image with `podman create` + `podman cp` so the host clangd can read the
  compiler's system headers).
- Put the host copy of the toolchain (~1 GB) in a **shared user-wide location**,
  not in the sidecar: `env("ARM_GNU_DIR", data_directory() / "arm-gnu" /
  <version>)`. One copy per version serves every checkout, worktree and project
  on that release. Make `toolchain` a no-op if `bin/arm-none-eabi-gcc` already
  exists, and copy to `<dir>.tmp` then `mv` so an interrupted copy never looks
  complete. Prefer user-wide to system-wide (no root, read-only data). Old
  versions are not removed automatically. (Using the IDE's bundled ST toolchain
  would save disk but differs from the release CI uses; not recommended.)
- `compdb` recipe: run `bear -- make -B BUILD=<tmp dir>` in the container
  (command-line variables override Makefile `:=`), then `sed` the container
  toolchain path and the bare `arm-none-eabi-gcc/g++` first arguments to the
  host copy and write `compile_commands.json` in the repo root.

- Image also carries a native `gcc` + `libc6-dev` when the repo has host-side unit
  tests (section 4b); the ARM tools are prefixed (`arm-none-eabi-gcc`), so the two never clash.

just gotchas:
- `{{...}}` is **not** interpolated inside string literals. Use concatenation:
  `mk := "make -j" + num_cpus() + " APP=" + app`. A literal `{{num_cpus()}}`
  reaching the shell gives `Syntax error: "(" unexpected`.
- Use `[private]` for helper recipes; call a symlinked justfile via
  `justfile_directory()` (verify it keeps the symlink location).

## 4. Editor (host) with clangd

- clangd must be allowed to ask the ARM gcc for its includes:
  `--query-driver=**/arm-none-eabi-*`.
- `.clangd`: remove flags clang does not know (`--specs=*`). Extend from the log
  if more are rejected.
- If the host editor is Helix, put the config in a symlinked `.helix/`
  (`languages.toml`). Helix 25.07+ also reads `.editorconfig`.

### Tab rendering

CubeIDE/CDT defaults to tabs, width 4. Repos usually mix tabs and spaces
(own code tabs, libraries 4 spaces, CubeMX/vendor code 2 spaces); measure per
directory before deciding, and never reformat to "fix" it.
- Helix's default for C/C++ may be 2 columns. Setting `indent = { tab-width = 4,
  unit = "\t" }` under `[[language]]` for `c` and `cpp` was **not enough** in
  practice.
- What worked: untracked nested `.editorconfig` files (one per top-level source
  directory, symlinked to one sidecar file, excluded) containing only
  `[*.{c,h,cpp,hpp}]` / `tab_width = 4`. Nested files win over a tracked
  root `.editorconfig`, and this changes rendering only, not indentation.
- Do not edit the tracked `.editorconfig`. The repo's may only contain
  Visual-Studio `cpp_*` keys, which no editor honours for this.

## 4b. Host-side unit tests (Unity + native gcc, in the container)

If the repo has a `test/` directory with its own Makefile (Unity, ASAN/UBSan,
one `test_<name>.c` + optional `.mk` with `SRCS`/`INCS` per test):
- `test` recipe: `just _run make -C test test {{args}}` (extra args e.g. `T=name`, `SAN=`).
- `test-compdb` recipe: writes `test/compile_commands.json` (clangd uses the
  nearest one, so it does not clash with the firmware one in the root).
- Give the test Makefile a `build` target (compile and link only) next to `test`
  (build and run), and make `test-compdb` call `build`, not `test`:
  `bear` injects a library with `LD_PRELOAD`, which the test binaries inherit,
  and ASAN then aborts with "ASan runtime does not come first in initial library
  list". Recording compile commands does not need the tests to run.
- Pass `BUILD=/tmp/...` (absolute) to keep the repo clean. The run loop must not
  do `./$$t`: with an absolute path it becomes `.//tmp/...: not found`. Loop over
  `$(abspath $(BINS))`.
- A Makefile that prints "all tests passed" must propagate failures: Unity's
  `return UNITY_END();` in `main`, and exit status checked per binary.
- When an ASAN binary aborts, piped output is lost; `script -qec ./bin /dev/null`
  shows it.

### clang-format profiles

Different directories follow different styles (tabs, spaces, vendored). Keep one
template per profile in `.devenv/clang-format/<profile>.clang-format` and a `clang-format`
recipe that symlinks it as `<dir>/.clang-format` for each directory in a list
(hidden via `.git/info/exclude`; nearest file wins; repo-root file is an "off"
fallback; vendored dirs such as `test/unity` get "off"). Re-runnable; a real
differing file is skipped unless `FORCE=1`.
- Tabs profile: `UseTab: AlignWithSpaces` (tabs only for leading indentation,
  spaces for alignment of `=`, trailing comments, declarations). Plain `Always`
  or `ForContinuationAndIndentation` puts tabs in alignment and looks broken in
  git previews and with other tab widths.
- `ColumnLimit: 0` and `ReflowComments: false` so existing code is mostly untouched.
- Wrap generated data and lookup tables in `// clang-format off` / `// clang-format on`.
- Add new library directories to the right list in the recipe.

## 5. Headless CubeIDE and the drift check (host only)

CubeIDE is Eclipse CDT and has a headless builder. It regenerates
`<app>/Debug/` without the GUI, compiles, and prints `Build Finished`.

```
<ide>/stm32cubeide -nosplash \
  -application org.eclipse.cdt.managedbuilder.core.headlessbuild \
  -data <throwaway workspace outside the repo> \
  -import <repo>/<app> -markerType cdt -cleanBuild <ProjectName>/Debug
```

- Do **not** pass `--launcher.suppressProfileCheck`; the CDT app rejects it
  (`Unknown argument`). Check the usage text it prints for valid options.
- `-import` takes the project directory; `-cleanBuild` takes
  `<project name regex>/<config>` (the name in `.project`, not the directory).
  `-markerType cdt` makes compile errors fail the run.
- Locate the install with an env var override (`/opt/st/stm32cubeide_*` default),
  use a throwaway workspace (`~/.cache/...`), and keep it all out of the repo.
  It only runs where CubeIDE is installed, so it cannot be part of CI.
- After the run, `git status` must still be clean (`Debug/` is gitignored).
  Verify the import did not modify `.project`, `.cproject`, `.settings/`.
- No official ST container is known; use the host install.

Drift check script (python3, run with `-I`), reading `Debug/**/subdir.mk`:
1. **Sources:** collect lines ending in `.c/.cpp/.s/.S`. Relative entries
   (`../Core/...`) are relative to `<app>/Debug`; absolute entries carry the
   checkout prefix CubeIDE saw, which is the common directory of all of them.
   Compare as a set against the CI source list (strip `\r` from the CI list).
   Report "only in CubeIDE" (CI would miss it) and "only in CI list". Fail if
   zero sources were found.
2. **Flags:** compare `-D -I -O -m -std -g -W -f*-sections -fno-* --specs` for C
   and for C++ separately, between the first compile line in CubeIDE's
   `subdir.mk` and a `make -n -B` dry run of the CI Makefile (no toolchain
   needed). Normalise `-I` to repo-relative paths, ignore flags only CI injects
   (version defines), ignore CubeIDE-only diagnostics flags.
3. Exit 1 on any difference. Wire `just check = cube-build check-sources`.

Expect real findings, e.g. include dirs present in CI's C++ flags but not in
CubeIDE's C++ settings. Decide with the user whether "only in the Makefile"
should be a warning (an extra include cannot change the binary) while "only in
CubeIDE" fails.

Optional later: generate the CI source list from `subdir.mk`. That is a repo
change, so it is the user's decision.

## 6. New clones and worktrees

- New clone of the same project: `git clone <private sidecar remote> .devenv`
  from the repo root (it must not exist yet), then `./.devenv/install.sh`, then
  `just image`, `just toolchain` (instant if the shared copy exists) and
  `just compdb`. The sidecar needs a private remote, or it only exists locally.
- A git worktree behaves like an independent folder: it needs its own sidecar
  clone, `install.sh` and `just compdb` (generated paths are absolute).
  `.git/info/exclude` is shared across worktrees, so the entries already exist.
- Use a separate `CUBE_WS` per clone/worktree: Eclipse maps a project name to one
  location, so two checkouts importing into one workspace can conflict.
- A different STM32 project is **not** a straight clone: app name, Makefile and
  source-list paths, the directories that get the nested editorconfig, tab
  choice and toolchain version are project-specific. Adapt them via this skill.

## 7. Working style that worked

- Report only what you verified. You cannot run podman/just/CubeIDE; label
  everything that way and ask the user to paste the first error.
- Prototype pure-python pieces (the checker) directly against any existing
  `Debug/` snapshot to get a real result before the host run.
- Give the user the exact commands to run (`image`, `build`, `toolchain`,
  `compdb`, `test`, `test-compdb`, `clang-format`, `cube-build`, `check`) and what a good result looks like.
- When a guess about a tool's flags or defaults turns out wrong, say so and fix
  it rather than defending it (this happened with a launcher flag and an editor
  default).
- Verify host-side claims by having the user run `git status`, `ls -l` on
  symlinks, and `hx --health`.
