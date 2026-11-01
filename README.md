# PR Review Bot

> A local, self-hosted AI pull-request reviewer for macOS, powered by Claude Code, OpenAI Codex or Gemini CLI.

![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white)
![GitHub CLI](https://img.shields.io/badge/GitHub_CLI-181717?style=for-the-badge&logo=github&logoColor=white)
![Claude](https://img.shields.io/badge/Claude_Code-D97757?style=for-the-badge&logo=claude&logoColor=white)
![OpenAI](https://img.shields.io/badge/Codex-412991?style=for-the-badge&logo=openai&logoColor=white)
![Gemini](https://img.shields.io/badge/Gemini_CLI-8E75B2?style=for-the-badge&logo=googlegemini&logoColor=white)

A local AI pull-request reviewer for macOS. Every 30 seconds it checks your GitHub
repos for new PRs or new pushes, reviews one PR with the engine you choose
(**Claude Code**, **OpenAI Codex** or **Gemini CLI**), and posts the review on the PR:
a verdict, issues grouped by severity (🔴 critical / 🟠 major / 🟡 minor) with
`file:line` and a concrete fix, and inline comments on the changed lines.

It runs on your machine, uses your own CLI logins or API keys, and comes with a local
dashboard for history, settings and cost.

## How it works

```
launchd (every 30s) ─► poll.sh ─► gh pr list ─► new PR or new head SHA?
                                                   │ one PR per tick
                                                   ▼
                  review.sh: fetch commit ─► dedicated git worktree (detached)
                           ─► engine CLI, headless + read-only ─► review JSON
                           ─► gh api: post review + inline comments ─► state.json
```

- **Your working copy is never touched.** Reviews run in `worktrees/`, detached at
  the PR's head commit. With no local clone configured, the bot keeps its own
  blobless clone in `clones/`.
- **Engines are read-only.** Claude Code gets only Read/Grep/Glob and read-only `git`/`gh`
  commands (`--permission-mode dontAsk`). Codex runs with `--sandbox read-only`, and
  Gemini with `--approval-mode plan`. None of them can edit files, push or post; the
  bot posts from the engine's structured output.
- **No overlap, no backlog storms.** A lock makes every tick exit immediately while
  a review is running. At most one PR is reviewed per tick. A PR is reviewed again
  only when its head SHA changes. After 3 failures on the same commit it waits for a new push.
- **Skips** drafts, bot PRs, a `no-review` label, chosen authors, and PRs that only
  touch docs or lockfiles.
- **Dashboard** on `http://localhost:5678`, served through launchd socket activation.
  Nothing runs until you open it. It binds to 127.0.0.1 only, checks the Host header,
  and accepts writes only from its own origin with a custom header.

## Requirements

- macOS (launchd)
- `git`, `jq`, `curl` (all preinstalled on recent macOS), and the [GitHub CLI](https://cli.github.com/), logged in
- At least one engine:
  - Claude Code: `npm i -g @anthropic-ai/claude-code`, then log in or set `ANTHROPIC_API_KEY`
  - Codex: `npm i -g @openai/codex`, then `codex login` or set `OPENAI_API_KEY`
  - Gemini CLI: `npm i -g @google/gemini-cli`, then log in or set `GEMINI_API_KEY`

## Install

```bash
git clone https://github.com/aryanbha123/pr-review-bot.git ~/pr-review-bot
cd ~/pr-review-bot
gh auth login            # or: pbpaste | gh auth login --with-token
./install.sh             # PRBOT_PORT=5678 PRBOT_LABEL=com.you.prreviewbot to customise
open http://localhost:5678
```

Then, in the dashboard under **⚙ Settings**:

1. Add repositories (`owner/repo`, plus an optional local clone path).
2. Pick an engine and model, paste API keys if you are not using CLI logins, and press **Test**.
3. Turn on **Post reviews on GitHub** when you are happy with the dry runs.

Posting is **off** after install. In that mode the bot only logs which PR it would
review. Before you turn posting on, mark the current backlog as seen so it doesn't
comment on every open PR:

```bash
./poll.sh --seed
```

## Everyday use

| | |
|---|---|
| Preview a review without posting | `./review.sh owner/repo 123 --dry-run` |
| Try another engine | `PRBOT_ENGINE=codex ./review.sh owner/repo 123 --dry-run` |
| Status in the terminal | `./status.sh` |
| Stop / remove | `./uninstall.sh` (keeps settings, keys and history) |
| Re-install after moving the folder or installing a new CLI | `./install.sh` |

Reviews are posted as the GitHub account `gh` is logged in as.

## Configuration

| File | What | In git? |
|---|---|---|
| `settings.json` | repos, engine, models, posting, limits, skip rules, price comparison (edited from the dashboard) | no |
| `.env` | `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, chmod 600. Empty = use the CLI's own login | no |
| `REVIEW_RULES.md` | what the reviewer looks for and how it reports | yes |
| `review-schema.json` | the structured output every engine must return | yes |

Each engine only receives its own key. Keys are never sent back to the dashboard,
which shows them masked (`sk-a…1b2c`).

Per-repo **extra rules** (Settings → Repositories) are appended to the prompt. Use
them for things like "apps/web and apps/admin share components, so check both copies".
Claude Code also reads the repo's `CLAUDE.md`, and Codex reads `AGENTS.md`.

## Cost

Claude Code reports a list-price cost per review (`total_cost_usd`). With a Claude
subscription login this counts against plan usage rather than being billed. Codex and
Gemini report token counts only. The dashboard compares your monthly spend with
per-seat tools (CodeRabbit, Greptile). Prices can be edited in Settings.

## Files at runtime

`state.json` (last reviewed SHA per PR), `history.jsonl` (one line per review),
`logs/` (daily logs, pruned after 7 days), `runs/` (per-review artifacts), `worktrees/`.
All are gitignored.

## Tech stack

- **Bash** scripts (`poll.sh`, `review.sh`, `lib.sh`, `config.sh`) driven by **launchd** agents generated from `templates/*.plist.in`
- **GitHub CLI** (`gh`) for listing PRs and posting reviews, plus `git`, `jq` and `curl`
- **Review engines**: Claude Code, OpenAI Codex CLI, Gemini CLI, constrained to `review-schema.json`
- **Dashboard**: a single `dashboard/index.html` with a shell API (`dashboard/api.sh`, `dashboard/serve.sh`)

## Project structure

```
pr-review-bot/
├── install.sh / uninstall.sh   # set up or remove the launchd agents
├── poll.sh                     # picks the next PR to review
├── review.sh                   # runs one review and posts it
├── status.sh                   # terminal status
├── lib.sh, config.sh           # shared helpers and settings loading
├── REVIEW_RULES.md             # reviewer instructions
├── review-schema.json          # structured output schema
├── settings.example.json, .env.example
├── dashboard/                  # local web dashboard (index.html, api.sh, serve.sh)
└── templates/                  # launchd plist templates
```

## Author

**Aryan Bhandari**: [GitHub](https://github.com/aryanbha123)
