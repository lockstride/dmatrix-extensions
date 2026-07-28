# dMatrix Decision Capture — Google (Antigravity CLI)

For Google, dMatrix targets **Antigravity CLI** (`agy`) — the CLI Google shipped for its
Antigravity agent platform at I/O 2026, and the path that replaces consumer Gemini CLI.
An Antigravity **plugin** bundles both parts of the setup — the behavior **and** the
connection to dMatrix — so a single install gives you a working integration (no separate
steps).

> **Why not the Gemini app or Gemini CLI?** The consumer Gemini app (and Gems) can hold
> instructions but **can't connect to dMatrix**, so nothing you discuss could actually be
> saved there. Gemini CLI stops serving free and individual-paid tiers on **June 18,
> 2026** (Gemini Code Assist Standard/Enterprise licenses keep working — see the [Gemini
> CLI note](#still-on-gemini-cli-enterprise) below). Antigravity CLI is the supported
> path where both parts work together.

## What you're installing

The dMatrix Antigravity **plugin** at [`antigravity/dmatrix/`](antigravity/dmatrix)
bundles both parts of the integration:

```
antigravity/dmatrix/
├── plugin.json                          # plugin marker
├── mcp_config.json                      # dMatrix MCP server (serverUrl)
└── skills/decide/SKILL.md               # decision-capture behavior
```

Sign up for a free dMatrix account at [dmatrix.com](https://dmatrix.com) first.

## Install (one step)

Point `agy` at the plugin bundle:

```bash
agy plugin install ./google/antigravity/dmatrix
```

Then verify both parts loaded:

```bash
agy plugin list      # dmatrix should be listed
```

Inside an `agy` session, `/skills` should list `decide` and `/mcp` should list the
`dmatrix` server (with its tools — `create_matrix`, `set_score`, …). Start a
conversation and Antigravity will offer to capture decisions in dMatrix, using the
`create_matrix` / `add_option` / `set_score` tools.

### Coming from Gemini CLI?

If you previously used dMatrix via a Gemini CLI extension, import your setup:

```bash
agy plugin import gemini
```

## Manual / two-step fallback

If you'd rather not install the bundle as a plugin, set up the two parts by hand:

1. **Behavior:** copy the skill into the CLI's global skills directory, e.g.
   `~/.gemini/antigravity-cli/skills/decide/SKILL.md` (or `.agents/skills/` inside a
   workspace, to scope it to one project).
2. **Tools:** add the dMatrix server to `~/.gemini/config/mcp_config.json` (global) or
   `.agents/mcp_config.json` (workspace):
   ```json
   {
     "mcpServers": {
       "dmatrix": { "serverUrl": "https://mcp.dmatrix.com/mcp" }
     }
   }
   ```
   The key must be `serverUrl` — Antigravity does not support the legacy `url` /
   `httpUrl` keys, and a misconfigured entry fails **silently** at startup.

Restart `agy` and confirm with `/skills` and `/mcp` inside a session.

## Still on Gemini CLI? (enterprise)

If you're on an enterprise Code Assist license and staying on **Gemini CLI** past the
June 18, 2026 consumer cutoff, the keys differ — Gemini CLI uses `httpUrl` (not
`serverUrl`) for a streamable-HTTP server, and reads instructions from `GEMINI.md`:

1. **Behavior:** put the decision-capture instructions in `~/.gemini/GEMINI.md` (global)
   or a project-root `GEMINI.md`.
2. **Tools:** add the server to `~/.gemini/settings.json`:
   ```json
   {
     "mcpServers": {
       "dmatrix": { "httpUrl": "https://mcp.dmatrix.com/mcp" }
     }
   }
   ```
Restart `gemini` and confirm with `/mcp`.

## Troubleshooting

- **`/skills` doesn't list decide** — recheck the install path (`agy plugin list`
  should show `dmatrix`); for the manual route confirm `SKILL.md` sits at
  `~/.gemini/antigravity-cli/skills/decide/SKILL.md` or `.agents/skills/` in the
  workspace, then restart `agy`.
- **`/mcp` doesn't list dmatrix** — confirm the MCP config uses `serverUrl` (not
  `httpUrl`/`url` — those fail silently) and lives at `~/.gemini/config/mcp_config.json`
  or `.agents/mcp_config.json`, then restart `agy`. On Gemini CLI it's the reverse —
  use `httpUrl` in `~/.gemini/settings.json`.
- **Tools fail to authenticate** — make sure you've signed in to your dMatrix account;
  the default server `https://mcp.dmatrix.com/mcp` requires one.
