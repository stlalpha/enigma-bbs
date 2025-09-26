# Repository Guidelines

## Project Structure & Module Organization
- `core/` contains the server runtime, message transports, and storage layers; `util/` holds shared helpers used across modules.
- `mods/` hosts optional features; register new mods through the HJSON in `config/` and document them in `docs/_docs/`.
- `config/` provides sample `.hjson` templates—keep defaults small and reference docs when adding keys.
- `www/` serves the bundled web UI, while `art/` and `misc/` carry ANSI assets and install tooling. `main.js` boots the node, `oputil.js` is the admin CLI.

## Build, Test, and Development Commands
- `npm install` (Node 22+) pulls dependencies and prepares Husky hooks from `mise`.
- `npm start` or `node main.js` launches a local board using the configs under `config/`.
- `node oputil.js users list` (or another subcommand) exercises operational flows without connecting with a client.
- `npm run pretty` formats the tree with Prettier; run it before opening a PR.
- `npx eslint .` uses `eslint.config.mjs` to catch style issues; pass `--fix` only after reviewing the diff.

## Coding Style & Naming Conventions
- JavaScript code uses four-space indentation, single quotes, required semicolons, and UNIX newlines; avoid trailing spaces.
- Prefer `const`/`let` over `var`, arrow callbacks, and CommonJS `require` statements without `.js` suffixes.
- Place new subsystems under `core/<area>/` and expose entry points as `index.js`; mods should mirror this under `mods/<modName>/`.
- Keep configuration names kebab-cased (`new-service-config.hjson`) and update the matching guide in `docs/_docs/`.

## Testing Guidelines
- There is no automated suite in-tree; validate changes by running `npm start` and walking the affected flows.
- Capture terminal output or screenshots when touching art under `art/` to confirm CP437 rendering.
- Log manual test steps in PR descriptions so reviewers can replay them.

## Commit & Pull Request Guidelines
- Follow concise, present-tense commit subjects (`Improve FTN export logging`); group logical changes together.
- Rebase locally to keep history linear before filing a PR.
- PRs should describe scope, config/documentation impacts, and manual verification; link GitHub issues or discussions when applicable.
- Attach relevant logs or screenshots for UI, network services, or asset tweaks, and note any follow-up tasks.

## Security & Configuration Tips
- Never commit node- or network-specific secrets; ship skeleton configs only and rely on local overrides.
- Rotate SSH/key material used during testing, and remove transient credentials from `config/` before pushing.
- Review `docs/_docs/servers/` after protocol changes so deployers stay informed.
