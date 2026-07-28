<p align="center">
  <img src="assets/dmatrix-logo.png" alt="dMatrix" width="120" height="120" />
</p>

# dMatrix Extensions

Bring dMatrix **decision-capture** to your favorite AI assistant. dMatrix notices when
you're weighing alternatives, evaluating trade-offs, or making a decision — and offers
to capture it as a structured, auditable decision matrix.

## Pick your assistant

| Assistant | Guide | One-step setup? |
|-----------|-------|-----------------|
| **Claude** (Code, claude.ai, Desktop) | [claude/README.md](claude/README.md) | ✅ One install in Claude Code — the app adds one click (plugin → Connectors → Install) |
| **OpenAI** (ChatGPT & Codex — one app) | [openai/README.md](openai/README.md) | ✅ One plugin install in the ChatGPT desktop app or Codex CLI — web adds the Skill + MCP server in two steps |
| **Google** (Antigravity CLI) | [google/README.md](google/README.md) | ✅ Antigravity plugin |

## Every setup has two parts — you need both

1. **The behavior** — instructions that teach the assistant *how* to capture a decision
   (when to offer, how to draw out options, criteria, and scores).
2. **The connection to dMatrix** — linking the assistant to your dMatrix account so it
   can actually create and save your decision matrix.

> **Both parts are required.** With only the behavior, the assistant can talk about your
> decision but can't create or save anything in dMatrix — so it ends up offering help it
> can't deliver. Always set up both. Some assistants do it in one step; others take two.
> Each guide walks you through it. You'll need a free dMatrix account — sign up at
> [dmatrix.com](https://dmatrix.com).

## What you get

Once set up, the assistant will:

- **Detect decision signals** — comparative evaluation, trade-off language, criteria-based
  reasoning, explicit "help me decide" framing.
- **Offer to capture** — a brief, non-blocking suggestion, never interrupting your flow.
- **Build a structured matrix** — options, criteria, scores, and weights, extracted from
  what you actually said.
- **Track provenance** — every value links back to its source, with confidence levels
  and citations.

Detection stays conservative — dMatrix only offers to capture on a clear decision signal,
and never interrupts.

### You can always ask

You don't have to wait for the assistant to notice a decision. At any point, type:

```
/dmatrix:decide
```

This works in Claude Code, Codex CLI, and Antigravity CLI. It tells the assistant to
capture a decision right now — even if you're mid-conversation, or looking back at a
decision you already made. The assistant will review what you've discussed and build a
matrix from it.

Use it when:

- You realize a past conversation contained a decision worth capturing.
- You want to structure a decision you're actively working through.
- The assistant didn't offer on its own and you'd like it to.

## Repository structure

```
shared/canonical-prompt/source.md   # The single source of truth (canonical behavior)
.claude-plugin/ · .codex-plugin/    # Claude + ChatGPT/Codex plugin manifests; self-vending marketplace
.mcp.json                           # Shared MCP wiring (one file, both plugins)
                                    # (this repo is its own single-plugin marketplace: source "./")
skills/decide/SKILL.md              # The dMatrix Skill (Claude & Codex plugins / standalone)
claude/README.md                    # Claude install guide (all surfaces)
openai/                             # ChatGPT web paste-in + manual Codex fallbacks (AGENTS.md, config.toml)
google/antigravity/dmatrix/         # Antigravity CLI plugin bundle
mcp/connectors/                     # Host-agnostic MCP connector reference
assets/                             # Brand logos (dM tile) — emitted by the renderer, used by the plugin manifests + this README
```

## How it works

Every behavior-bearing artifact is **generated from one source**,
`shared/canonical-prompt/source.md`, by the renderer pipeline in the dMatrix monorepo
(`packages/canonical-prompt`). The pipeline injects the canonical body **verbatim** into
each surface — only the per-provider wrapper differs — and stamps a content hash
(`version_hash`) so every artifact stays provably in sync. To re-sync after the canonical
prompt changes, the pipeline regenerates this whole repo in one run; the artifacts here
are not edited by hand.

## License

Copyright © 2026 Oxford Heavy Industries, LLC. All rights reserved. dMatrix is a product
of Lockstride, a division of Oxford Heavy Industries, LLC.

These extensions are **free to install and use** with your own dMatrix account. They are
not open source: copying, redistribution, modification, and derivative works are not
permitted, and the dMatrix name, logos, and icons are trademarks that this license does
not grant any right to use. See [LICENSE](LICENSE) for the full terms.

## Support

- Issues: [github.com/lockstride/dmatrix-extensions/issues](https://github.com/lockstride/dmatrix-extensions/issues)
- dMatrix account & app: [dmatrix.com](https://dmatrix.com)
