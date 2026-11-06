---
description: Set up a local rootless-Podman dev container driven by `just`, with Helix, language servers and the project toolchain inside it, so dependency code never runs on the host. Use when the user wants a private "dev env in a container" for a project (any stack), or is debugging one built this way (uid/permission errors, Helix log errors, LSP showing nothing, port not reachable).
---

# Podman + just dev environment

A long-lived container holds the editor (Helix), language servers and the
toolchain. The project directory is bind-mounted; `just` recipes start the
container on demand and `podman exec` into it. Nothing the project installs
runs on the host.

Templates to copy and adapt: `templates/dev.just`, `templates/dev.Dockerfile`,
`templates/languages.toml`. Read them before writing anything; they hold the
working flags.

## Layout to produce

```
justfile          imports dev.just; project tasks (e.g. `web`, `api`) go here
dev.just          container plumbing: build, up, dev/hx/shell, stop, clean
dev.Dockerfile    base image + Helix + toolchain (+ LSPs)
.helix/languages.toml   project-local LSP config (committed)
```

The user's Helix config is mounted read-only from the host, so it is never
duplicated. Language servers are configured per project in `.helix/`, not in
the user's global config.

## Steps

1. Ask which stack(s) the project needs (runtime, package manager, LSPs). Do
   not assume Deno or Python.
2. Copy the templates, set the image/container names and the toolchain.
3. Add project recipes to `justfile` (`podman exec` with `--workdir` set).
4. `just dev-rebuild`, then `just hx --health <language>` to confirm each LSP.

If `podman` or `just` is not installed where you are working, say so and give
the user the commands to run. Do not claim anything was built or tested.

## Rules that avoid the known failures

**Users and permissions (the biggest trap)**
- Run rootless. Do not assume the image `USER` maps to the host user.
- Plain `--userns=keep-id` does NOT make an image with `USER something` run as
  you; files then look unwritable. Use `--userns=keep-id:uid=<image uid>,gid=<image gid>`
  (Podman >= 4.3) so the image's user maps onto the host uid. Find the uid with
  `id` inside the container.
- The uid is image-specific: re-check it when bumping the base image.
- A project from a Windows zip can have read-only dirs (mode 555). Fix on the
  host: `chmod -R u+rwX,go+rX,go-w .`
- Named volumes keep the ownership they had when first filled. If you change the
  user mapping, remove and recreate the volume (it is only cache).

**Home, config, terminal**
- Set `--env HOME=/tmp`. Without a real home, Helix fails with "failed to
  initialize logging".
- Set `--env XDG_CONFIG_HOME=/config` and mount the host Helix config at
  `/config/helix:ro,Z`. Skip the mount if the host directory is missing.
- Pass `--env TERM=$TERM --env COLORTERM=truecolor` on every `podman exec -it`,
  or colours and keys break.
- Clipboard: set `[editor] clipboard-provider = "termcode"` (OSC 52) in the
  project `.helix/config.toml` (Helix >= 25.07) so yanks reach the host
  clipboard through the terminal. It is write-only: paste with the terminal's
  own key. That is also the safest option, because the container cannot read
  the host clipboard. Two-way sync needs a Wayland socket mount or a TCP
  bridge, both of which let the container read the clipboard; say so first.
- Recipes that use `podman exec -it` cannot be backgrounded (`&`): the job is
  suspended on tty input or fails with "input device is not a TTY". For a
  background run use `podman exec` without `-it` (or `-d`).

**Volumes and state**
- Put caches (package cache, language runtimes, venvs) on named volumes, not in
  the bind-mounted project. Mount them at the path the tool actually uses
  (check the env var, e.g. `DENO_DIR`, `UV_CACHE_DIR`); a mismatched path
  silently makes the volume useless.
- A venv built in the container must not live in the repo: it is built for the
  container's OS. Use a volume plus `UV_PROJECT_ENVIRONMENT` (or equivalent).
- Changed `podman run` flags only apply to a NEW container: tell the user to
  run `dev-clean` (or `dev-rebuild`) after editing them.

**Ports**
- `--publish <port>:<port>` for anything the host browser must reach, and make
  the server listen on all interfaces (`--host` for Vite, `0.0.0.0` elsewhere).
  Inside the container `localhost` is the container, not the host.
- If frontend and backend both run in the container, a dev-server proxy to
  `localhost:<backend port>` works and avoids CORS. Publish only the frontend.

**Hardening that is cheap and kept**
- `--cap-drop=all --security-opt=no-new-privileges`.
- No SSH agent, no git credentials, no gitconfig in the container by default.
  Commit and push from the host. If the user explicitly wants agent forwarding,
  make it opt-in and say what it exposes: any code in the container (including
  dependencies) can use the loaded keys.
- Private git dependencies (e.g. `uv`/`npm` pulling `ssh://git@github.com/...`):
  prefer a read-only GitHub deploy key over agent forwarding. Store it as a
  podman secret (`podman secret create <name> <keyfile>`) and mount it only
  if the secret exists: `--secret <name>,uid=<image uid>,gid=<image gid>,mode=0400`
  (a bind-mounted key gets the wrong owner under `keep-id` and ssh rejects
  it). Point git at it with `GIT_SSH_COMMAND='ssh -i /run/secrets/<name> -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts'`.
  A deploy key belongs to ONE repo, so it only fits a single private
  dependency; several private repos need a fine-grained token plus an
  `insteadOf` URL rewrite, if the org allows tokens. Ideally one key per
  developer plus one for CI; a shared dev key is fine for a tiny team.
  Remind the user the secret is only mounted on a NEW container.
- Do not over-engineer supply-chain checks inside the container. With no
  credentials in it, the realistic loss is the project source. Pin versions;
  checksum-verified downloads are optional (keep them only if the user wants).

**Language servers (Helix)**
- Configure in `.helix/languages.toml`; it merges over the global config.
- Check with `hx --health <language>`, then `:log-open` and `:lsp-restart`.
- Deno LSP: Helix answers `workspace/configuration` from the `config` table, so
  the settings must be nested under a `deno` key as well as flat, or the server
  runs but returns nothing (no hover, no diagnostics). See the template.
- Hover is `space k`, definition `gd`; useful to tell "server dead" from "wrong key".
- Python: ruff alongside one type checker (ty by default, pyright commented as
  the alternative). ty is a separate Astral tool, not bundled with uv. Type
  checkers may not find a venv kept outside the project; set `VIRTUAL_ENV` and
  `PATH` for it if imports show as unresolved.

## Splitting justfiles

Keep container plumbing in `dev.just` and `import 'dev.just'` from the
`justfile` (not `mod`: `import` shares recipes and variables, so project
recipes can depend on the private `_dev-container-up`).

## Cleanup (tell the user, do not run without being asked)

`podman container prune`, `podman image prune` (dangling images from rebuilds),
`podman volume ls` before `podman volume prune`. Never suggest
`podman system prune -a --volumes` casually: it wipes every project's images and
volumes.

## Writing the files

Run nothing destructive. Do not commit unless asked. Keep the Dockerfile
stages small and pinned; one stage per downloaded tool, copied into the final
image. Mention anything you could not verify (no Podman available, untested
flags).
