# dMatrix Decision Capture — OpenAI (ChatGPT & Codex)

As of the July 2026 release, **OpenAI runs one stack.** The Codex app merged into the
**ChatGPT desktop app** — Chat, Work, and Codex are now modes inside a single app that
share one **Plugin Directory** (it replaced the old App Directory), and the **Codex CLI**
reads that same plugin system. So on the desktop app and the CLI, dMatrix is a **single
plugin install**. The ChatGPT **website** keeps its own point-and-click setup, where you
add the two pieces individually.

| You're using… | Setup | Jump to |
|---------------|-------|---------|
| **ChatGPT desktop app** (Chat / Work / Codex) or the **Codex CLI / IDE** | ✅ One install — the dMatrix plugin bundles both pieces | [Install the plugin](#install-the-plugin) |
| **ChatGPT on the web** (chatgpt.com) | Two quick steps — add the **Skill**, then the **MCP server** | [ChatGPT web setup](#chatgpt-on-the-web) |

Either way you're setting up the same two parts:

1. **The behavior** — instructions (packaged as the dMatrix **Skill**) that teach the model
   how to capture a decision as a structured matrix.
2. **The connection** — the dMatrix **MCP server**, so the model can actually create and
   save your matrices. With only the behavior, the model offers help it can't deliver.

The plugin bundles both. On the web you add them as two steps — the Skill and the MCP
server — from the same **Plugins** area in the sidebar. Sign up for a free dMatrix account
at [dmatrix.com](https://dmatrix.com) before you start.

---

## Install the plugin

*(ChatGPT desktop app & Codex CLI/IDE)*

The plugin bundles the decide **Skill** *and* the dMatrix **MCP server** — one install,
both parts. In a terminal:

```bash
codex plugin marketplace add lockstride/dmatrix-extensions
codex plugin add dmatrix@dmatrix-extensions
```

Prefer menus? Run `/plugins` inside a Codex session, or open the **Plugin Directory** in
the ChatGPT desktop app, and install from there instead.

- **One install covers the whole app.** Because Chat, Work, and Codex share the desktop
  app's plugins, installing once makes dMatrix available in every mode. Install from the
  terminal (or the Plugin Directory), then **restart the ChatGPT app** to pick it up.
- **Sign in once.** The first time dMatrix connects you'll approve access in the browser
  (OAuth). If you're ever asked again later, that's normal — just re-approve.
- **Verify:** `codex mcp list` shows the `dmatrix` server, and `codex plugin list` shows
  the plugin enabled. A new session offers to capture when you're weighing a decision.
- **Update later:**

  ```bash
  codex plugin marketplace upgrade dmatrix-extensions
  codex plugin add dmatrix@dmatrix-extensions
  ```

### Manual setup (no plugin)

Prefer explicit local config? The two parts install by hand:

1. **Behavior** — copy [`codex/AGENTS.md`](codex/AGENTS.md) to `~/.codex/AGENTS.md`
   (global) or `AGENTS.md` in one project's root.
2. **Connection** — `codex mcp add dmatrix --url https://mcp.dmatrix.com/mcp`, or merge
   [`codex/config.toml`](codex/config.toml) into `~/.codex/config.toml`.

Codex supports remote streamable-HTTP MCP servers directly — no `mcp-remote` bridge or
feature flag needed.

---

## ChatGPT on the web

The website can't install this repo's plugin, so you add the two parts as two steps —
both from the **Plugins** area. You'll need a **paid plan** (Plus, Pro, Business,
Enterprise, or Edu); custom plugins and Skills aren't available on Free. On
Business / Enterprise / Edu, a **workspace admin** may need to turn these on first.

### Part 1 — add the behavior (the decide Skill)

ChatGPT web supports **Skills** — reusable, uploadable workflow packages. The decide Skill
ships here **pre-packaged with its dMatrix icon and metadata**, so it appears as **dMatrix**
(with the logo) in the skill picker and triggers proactively when you're weighing a decision.

1. In the left **sidebar**, click **Plugins**, then open the **Skills** tab in the Plugin
   Directory.
2. Click **Create → Upload from your computer**.
3. Upload **decide.zip** — download it from the
   [latest release](https://github.com/lockstride/dmatrix-extensions/releases/latest/download/decide.zip)
   and drop it in. It's already in the shape ChatGPT expects: a top-level `decide/` folder
   holding `SKILL.md`, `agents/openai.yaml` (the icon + display name), and the `assets/`
   icons.
4. ChatGPT scans the upload; once it clears, every chat applies dMatrix decision-capture
   behavior. (An upload can land as **Needs Review** or **Blocked** — that's ChatGPT's
   safety scan; approve it from the Skills tab.)

Prefer to build it from a clone? `cd skills && zip -r ../openai/decide.zip decide -x 'decide/README.md'` reproduces the same bundle.

> **Simpler, unbranded alternatives** — these skip the packaged upload, so ChatGPT shows a
> generic auto-icon instead of the dMatrix logo. Use them if you're on a plan without
> Skills, or an upload gets blocked:
> - **Create → Create with editor**, then paste the contents of
>   [`../skills/decide/SKILL.md`](../skills/decide/SKILL.md).
> - Or put the behavior in a **Project's** custom instructions: open
>   [`paste-in/dmatrix.md`](paste-in/dmatrix.md), copy the **entire** contents, and paste.
>   A single chat (one-off) or a **Custom GPT**'s instructions work too.

### Part 2 — connect to dMatrix (the MCP server)

Adding a custom MCP server needs **Developer mode** (in beta), on a paid plan. On
Business / Enterprise / Edu an admin enables it first (Workspace Settings → Permissions,
"custom MCP connectors / Developer mode").

1. **Turn on Developer mode.** Open **Settings → Plugins** and **scroll to the bottom** —
   toggle on **Developer mode**. *(OpenAI shuffles this label; if it's not there, look
   under **Settings → Security and login** or **Settings → Connectors**.)*
2. **Add the server.** In the sidebar, click **Plugins** (or go to `chatgpt.com/plugins`),
   then click the **+** next to the plugins search bar to create a custom plugin.
3. **Fill in:**
   - **Name:** `dMatrix`
   - **MCP Server URL:** `https://mcp.dmatrix.com/mcp`
   - **Authentication:** **OAuth.** dMatrix signs you in through your browser and ties the
     connection to your account. *Don't choose No authentication* — the server needs the
     sign-in to read or write your matrices.
4. Click **Create.** The new plugin lands under **Drafts**. To use it in a chat, click
   **+** near the message box, choose **More** (some accounts label this **Developer
   mode**), and select **dMatrix**.

When dMatrix writes to a matrix (e.g. `create_matrix`, `set_score`), ChatGPT asks you to
confirm the first time in each conversation — that's expected.

The Skill (Part 1) and the MCP connection (Part 2) are independent: the Skill carries the
behavior, the MCP server carries the account connection. Set up both — with only one, the
model can talk about your decision but can't save it (or vice-versa).

---

## Troubleshooting

- **The model doesn't offer to capture decisions** —
  - *Plugin:* confirm it's installed and enabled (`codex plugin list`), then start a *new*
    session (and restart the ChatGPT desktop app if that's where you're working).
  - *Web:* confirm the Skill finished scanning and is enabled in the **Skills** tab — or,
    if you used the paste-in, that the instructions were pasted in full into the Project.
- **The model can't create or save a matrix** — the dMatrix connection isn't active:
  - *Plugin:* `codex mcp list` should show `dmatrix`. If it's listed but tools are
    unavailable (or the logs show an OAuth error), reconnect with `codex mcp login dmatrix`
    and approve in the browser.
  - *Web:* you need Developer mode on a paid plan, and the dMatrix plugin must be selected
    in the current chat (**+ → More → dMatrix**).
- **Can't find Developer mode on the website** — it's beta and paid-plan only. Look under
  **Settings → Plugins** (scroll to the bottom); on Business / Enterprise / Edu a workspace
  admin enables it first.
- **The Skill upload says "Needs Review" or "Blocked"** — ChatGPT scans every uploaded
  Skill. Open the **Skills** tab to review and approve it; if it stays blocked, use the
  Project paste-in fallback above.
