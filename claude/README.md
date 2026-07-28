# dMatrix Decision Capture — Claude

Set up dMatrix decision-capture in any Claude product. Pick the row that matches
how you use Claude:

| You use… | Jump to | One install or two steps? |
|----------|---------|---------------------------|
| **Claude Code** (terminal / IDE) | [Claude Code](#claude-code) | **One** — the plugin bundles everything |
| **claude.ai** or **Claude Desktop** (the app) | [The Claude app](#the-claude-app-claudeai-and-desktop) | **Two** — install the plugin, then its connector |
| Claude Code, but no marketplace | [Standalone skill](#standalone-skill-advanced) | Two steps |

## What you're setting up — two parts, both required

1. **The behavior** — a Skill that teaches Claude how to capture a decision as a
   structured matrix (when to offer, how to draw out options, criteria, and scores).
2. **The connection to dMatrix** — linking Claude to your dMatrix account so it can
   actually create and save your decision matrix.

> **You need both.** With only the behavior, Claude can talk through your decision but
> can't create or save anything in dMatrix — so it ends up offering to capture decisions
> it can't deliver. The plugin bundles both parts: in Claude Code one install wires up
> everything, while the Claude app takes one extra click to install the plugin's
> connector. The manual and standalone routes add the two parts by hand.

---

## Claude Code

**One install gets you both parts.** The plugin bundles the Skill and wires up the
dMatrix MCP server automatically.

In Claude Code, run:

```
/plugin marketplace add lockstride/dmatrix-extensions
/plugin install dmatrix@dmatrix-extensions
```

That's it. Start a new conversation and Claude will offer to capture decisions in
dMatrix. (Prefer a menu? Just run `/plugin` and browse the **Discover** tab.)

> **Sign in to dMatrix:** the plugin's MCP server registers automatically, and Claude
> Code notices at startup that it needs authentication. Run `/mcp`, select `dmatrix`,
> choose **Authenticate**, and complete the browser sign-in — once, then it's cached.
> Create a free account at [dmatrix.com](https://dmatrix.com).

---

## The Claude app (claude.ai and Desktop)

The app supports the **same plugin** as Claude Code — installed from a menu, no
terminal. One difference from Claude Code: the app installs the plugin's **Skill**
right away, but its bundled **connector** needs one more click before Claude can
reach dMatrix.

### Recommended — install the plugin, then its connector

1. Open **Customize → Plugins** from the left sidebar.
2. Click **Add → Add marketplace → Add from a repository**.
3. Paste this repository URL, then add it — Claude syncs the marketplace for you:
   `https://github.com/lockstride/dmatrix-extensions`
4. Once it's added, open the **Personal** tab to see the available plugins.
5. Find the **dMatrix Decision Capture** card, click **Install**, and accept the
   trust prompt.
6. Last, connect the plugin to dMatrix: open the installed plugin, switch to its
   **Connectors** tab, click **Install** next to `dmatrix`, and sign in when
   prompted.

> Step 6 is the classic first-run trap: skip it and `/dmatrix:decide` will load, but
> Claude will report that the dMatrix tools aren't reachable — the Skill is installed
> while the connector isn't. The plugin card doesn't flag this; the **Connectors** tab
> is where the missing half lives.

That's the whole setup. You can manage or remove the plugin anytime under
**Customize → Plugins**.

> **Staying up to date:** on the marketplace's **⋯** menu, turn on
> **Sync automatically** (or use **Check for updates**) — new dMatrix releases then
> surface an **Update** button on the plugin. If you installed dMatrix before
> v0.14.0 from `lockstride/claude-marketplace`, uninstall that copy and reinstall
> from this repo's marketplace — the old marketplace no longer lists dMatrix, so
> updates never reach it.

### Manual — add the two parts by hand

If you'd rather not use a plugin, add the same two parts in **Settings**:

**Part 1 — add the behavior:**
1. Download **[`decide.zip`](https://github.com/lockstride/dmatrix-extensions/releases/latest/download/decide.zip)**
   from the latest release — it's already the right shape (the `decide/` folder at the
   zip's top level with `SKILL.md` inside it). Building from a clone instead? Zip **the
   folder itself** (`skills/decide/`), *not* the files loose at the root.
2. In Claude, turn on **Code execution and file creation** under **Settings →
   Capabilities**, then go to **Customize → Skills** and click **+** to upload the
   zip. (On Team/Enterprise, an org Owner must enable both under **Organization
   settings → Skills** first.)

**Part 2 — connect to dMatrix:**
1. Go to **Customize → Connectors**, click **+**, then **Add custom connector**.
2. Name it `dMatrix` and enter the URL `https://mcp.dmatrix.com/mcp`.
3. Click **Add**, then sign in to dMatrix when prompted.

On Team/Enterprise, an Owner must first add it under **Organization settings →
Connectors**; members then click **Connect** under **Customize → Connectors**.

Both parts are now active in every new conversation.

---

## Standalone skill (advanced)

If you want the Skill in Claude Code **without** the marketplace plugin, install the
two parts by hand:

**Part 1 — add the behavior:**
```bash
cp -R skills/decide ~/.claude/skills/decide
```
Claude Code auto-discovers it on the next session. (Use `.claude/skills/` inside a
project instead, to scope it to one repo.)

**Part 2 — connect to dMatrix:**
```bash
claude mcp add --transport http dmatrix https://mcp.dmatrix.com/mcp
```
Verify with `claude mcp list` (or `/mcp` inside a session).

> The marketplace plugin does both of these for you — prefer it unless you have a
> reason to install the Skill on its own.

---

## Troubleshooting

- **Claude doesn't offer to capture decisions** — make sure the Skill is installed
  (Claude Code: `/plugin` → Installed, or check `~/.claude/skills/`; app plugin:
  **Customize → Plugins**; app manual: **Customize → Skills**). In Claude Code, a
  freshly installed plugin loads after `/reload-plugins` or a new session. Try a
  clearer decision ("help me choose between A and B on cost and speed").
- **Claude won't create or save a matrix / "dMatrix tools aren't reachable"** — the
  connection to dMatrix isn't set up. App plugin: open **Customize → Plugins →
  dMatrix Decision Capture → Connectors** and make sure `dmatrix` is **installed and
  signed in** — plugin install alone doesn't do this ([step 6](#recommended--install-the-plugin-then-its-connector)).
  App manual route: **Customize → Connectors** should list `https://mcp.dmatrix.com/mcp`.
  Claude Code: run `/mcp` and authenticate the `dmatrix` server (or check
  `claude mcp list`).
- **Can't add the marketplace or the dMatrix plugin card is missing (app)** — on
  Team/Enterprise, plugins must be enabled for the org by an Owner first; if the
  option is missing, ask your admin or use the manual two-part route instead.
- **"This plugin uses a source type your Claude Code version does not support"** —
  update Claude Code to the latest version, then re-run the install commands.
