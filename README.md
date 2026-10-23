# Loro starter — build a private personal voice agent

This is the **architecture, ops and decisions** half of a small private personal agent that you can talk
to (phone, Telegram, or a push-to-talk web app), that remembers you, calls tools, and verifies facts
before answering.

It is a *starter kit*, not a working clone. It contains the parts that are hard to get right the first
time — the reasoned trade-offs, the server layout as code, the systemd units, the traps — and deliberately
**does not** contain the reference build's application code or its private configuration.

## Start here

**`ADOPTION_GUIDE.md`** is written for an AI agent to read and then walk its human through. Point your
agent at it and say something like:

> Read `ADOPTION_GUIDE.md` in this repo. Interview me using its §2 decision list before you build
> anything, explain each trade-off in plain language, then give me a build plan with the checks from §4.

It ends with a 9-question interview (surfaces, cloud vs local speech, brain, privacy posture, language,
budget, memory and who may read it, other users and their consent, whether you will evaluate it) — the
things people usually only discover they cared about halfway through.

## What's here

| Path | What it is |
|---|---|
| `ADOPTION_GUIDE.md` | Architecture, the decision interview, build order with a check per step, the traps, security minimums |
| `ops/rebuild/REBUILD.md` | Rebuilding the server from these files, in order, each step with a verification |
| `ops/rebuild/systemd/` | Service units: agent worker, memory worker, LiveKit, Redis drop-in, backups, dashboard, SIP bootstrap |
| `ops/rebuild/caddy/Caddyfile` | Reverse proxy config with placeholder domains |
| `ops/rebuild/livekit/` | LiveKit + SIP configuration, secrets as `${PLACEHOLDER}` |
| `ops/rebuild/redis/` | The Redis subset that actually matters (bind addresses, persistence) |
| `ops/rebuild/snapshots/` | Reference-box snapshots: ufw status, crontab, pip freeze, tailscale notes, versions |
| `ops/rebuild/scan_secrets.sh` | Fails if anything key-shaped appears in the tree. Run it before publishing your own |
| `prompts/loro_en.md`, `prompts/loro_es.md` | The persona and tool-routing prompt, one file per language — the most instructive single artifact here |
| `.env.example` | Every environment variable the stack expects, values blank |

## What is deliberately not here

The application code (`agent/`), the evaluation harness (`evals/`), the dashboard, and every real
credential, ID, hostname and IP. The reference build's own copy is private. You are meant to write your
own agent loop against the prompts and the ops scaffolding here, or adapt an existing agent framework.

## The short version of the architecture

One agent loop, several doors: a LiveKit media server for speech, a small HTTP server for the
push-to-talk app, and a chat gateway for Telegram. One SQLite memory store per person. Speech and
reasoning are separate vendors, so you can trade privacy against quality on each independently. The
private-network posture (tailnet, no public ports) *is* the security model.

## Before you publish anything built from this

`bash ops/rebuild/scan_secrets.sh` — it should print nothing and exit 0. Then grep your own tree for your
phone number, your Telegram ids, your server IP and your tailnet name. This kit was scrubbed of exactly
those things; yours will accumulate them the moment you deploy.

## Licence

MIT — see `LICENSE`. The prompts and ops configs are examples from a personal build; read them, adapt
them, and check the licences of the models and services you point them at.
