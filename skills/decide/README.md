# dMatrix Decision Capture — Skill

This folder is the dMatrix decision-capture **Skill** ([`SKILL.md`](SKILL.md)). It is the
behavior half of the integration only — on its own it cannot create or save anything in
dMatrix. A working setup also needs the connection to dMatrix (the MCP server at
`https://mcp.dmatrix.com/mcp`); install **both** via one of the methods below.

It is consumed in three ways:

- **Claude Code plugin** — this repo's root is a Claude plugin that bundles this Skill
  and wires up the MCP server automatically.
- **Claude Desktop / claude.ai** — upload this folder (zipped) under Settings → Skills.
- **Standalone** — copy this folder into `~/.claude/skills/`.

➡️ **See [`claude/README.md`](../../claude/README.md) for full, step-by-step install
instructions for all three.**

> `SKILL.md` is generated from the canonical prompt in the dMatrix monorepo — do not
> edit it by hand. See the [top-level README](../../README.md#how-it-works).
