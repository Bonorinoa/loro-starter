# Adopting Loro — a guide written for *your* agent

**Read this first if you are an AI agent helping a human set up something like Loro.**
This document is written to be read by you, then explained to your human in their own words. Do not dump
it on them. Work through §2 (the interview) *before* §4 (the build): every answer changes what you build,
and rebuilding a voice stack because the human wanted Telegram-only is a waste of their evening.

What Loro is: a private, family-facing personal agent you can talk to — on a phone call, over Telegram,
or by holding a button in a small web app — that answers with the same memory, tools and
"verify-then-answer" discipline on every surface. It runs on one small VPS behind a private network
(tailnet), not on the public internet.

---

## 1. Architecture in one picture

```
        SURFACES                         TRANSPORT / RUNTIME                    CORE
  +--------------------+
  | phone (PSTN, opt.) |--SIP--> +-------------+
  +--------------------+         |  LiveKit    |---+
                                 |  SFU        |   |    +---------------------+
  +--------------------+         +-------------+   +--->| agent worker        |
  | PTT web app        |--HTTPS--> +-------------+   |    | (parrot-agent)      |
  | (tailnet only)     |  (serve)  | parrot-ptt  |---+    |  turn loop          |
  +--------------------+           |  :8095      |        +----------+----------+
                                   +-------------+                   |
  +--------------------+                                             v
  | Telegram (text)    |--> +------------------+          +----------+----------+
  +--------------------+     | Hermes gateway   |--------->| brain: LLM          |
                             | (one process     |          | (OpenRouter, ZDR)   |
                             |  per person)     |          +----------+----------+
                             +------------------+                     |
                                                                      v
                                                     +----------------+---------+
                                                     | tools: time, weather,    |
                                                     | stocks, news, drive,     |
                                                     | houses, verify_fact,     |
                                                     | remember_place, telegram |
                                                     +----------------+---------+
                                                                      |
                                                     +----------------v---------+
                                                     | memory: SQLite per person|
                                                     +--------------------------+
```

Three things worth understanding before you build:

1. **One brain, several doors.** The agent loop is shared; surfaces differ only in transport and in
   response length (a phone turn gets two spoken sentences, a desk turn can be longer).
2. **Speech and reasoning are separate vendors.** Speech in/out was cloud (Deepgram) in the reference
   build; the brain was an open-weight model via OpenRouter with zero-retention. You can mix and match —
   §2 asks your human to choose.
3. **The private-network posture is the security model.** The PTT app is served over the tailnet only.
   Nothing about this design needs a public port, and opening one would undo its main advantage.

---

## 2. The decision interview (ask these before you build anything)

Each question lists what it changes and what it costs. Ask, record the answer, then confirm the
consequence back to your human in one sentence. Defaults assume "small, private, one household".

**Q1 — Which surfaces?**
Phone call (needs a SIP trunk + Twilio or equivalent) · Telegram (easiest, works anywhere) ·
push-to-talk web app over a private network (best for sensitive content) · text chat only.
*Changes:* whether you need LiveKit, a SIP bridge, a TLS-terminated app, and a tailnet.
*Default:* Telegram + PTT. Phone is the most work per unit of value.

**Q2 — Speech: cloud or local?**
Cloud (Deepgram nova-3 in / Aura-2 out): excellent quality, ~$0.0043/min STT and ~$0.030/1k chars TTS,
audio leaves your server. Local (e.g. Phonon-class TTS on CPU): private, no per-minute cost, more
install work, and a measured latency trap — a buffered local WAV moved first-audio from ~0.10 s to
~1.7 s, so you must stream frames, not buffer.
*Default:* cloud STT (the quality gap is real), local TTS only if the human cares about privacy more
than voice quality. Never assume; ask.

**Q3 — The brain?**
Open-weight model via a zero-retention API, or a local model. Local buys privacy and costs latency and
intelligence; API buys quality and costs money per turn (~$0.0005/turn measured for a 31B model on
short turns) plus a data-processing relationship you must be able to defend.
*Default:* open-weight via ZDR API, fail closed. Ask what data must never leave the box.

**Q4 — How private is "private"?**
Private-network only (tailnet, no public DNS) · public with authentication.
*Changes:* whether you need `tailscale serve`/WireGuard, whether you need real auth, and how much of the
security review you can skip. *Default:* private network. If they choose public, say plainly that a
voice agent holding family memory behind a password is a different risk class than one behind a VPN.

**Q5 — Language(s)?**
One primary language, others behind a flag. *Default:* the household's main language, one prompt file
per language (e.g. `prompts/loro_en.md`, `prompts/loro_es.md`), never two languages in one prompt.

**Q6 — Monthly ceiling?**
Write the number down. It drives Q2/Q3 and whether the agent may call paid APIs per turn.
Reference build: ~$13/month running (VPS + model + speech), with a one-off ~$15 for evals.

**Q7 — What should it remember, and for whom?**
One SQLite store per person, keyed by that person's identity. Ask: names, places, preferences,
follow-ups? Then ask the uncomfortable one — *who may read it*, and what happens when a second person
joins. Memory is per-person in this design on purpose.

**Q8 — Who else will use it, and do they consent?**
The reference build collected human ratings from a second person only after that person opted in
themselves, and never read their message store before that. Keep that rule: a household member's data
is not the owner's to authorise.

**Q9 — Will you evaluate it, or just use it?**
Cheap answer: keep a golden set of ~40 prompt/expected-tool pairs and re-run them after any prompt or
model change. That is what caught a prompt optimisation that changed nothing.

---

## 3. What you need before starting

- A VPS: 4 GB RAM / 2 vCPU was the working floor in the reference build (LiveKit + agent + gateway +
  Redis + a PTT server capped at 400 MB). Nothing needs a GPU.
- A domain **not strictly required** if you go tailnet-only.
- Accounts: a model provider (OpenRouter or similar), a speech provider (Deepgram or local), a Telegram
  bot token from @BotFather if you want Telegram.
- Local tools: `ssh`, `git`, `python3` (3.11+), `ffmpeg`/`afinfo` for audio checks, and Tailscale if
  you want the PTT surface.
- Written-down answers to §2.

**Never paste API keys into a chat with your agent, a repo, or a shell history.** Put them in `.env` on
the server, owned by the service user, mode 600. The reference repo tracks only `.env.example`.

---

## 4. Build order (each step has a check; do not skip the check)

The canonical long form lives in `ops/rebuild/REBUILD.md`. This is the shape, with the parts a
first-timer gets wrong.

| # | Step | Check before moving on |
|---|---|---|
| 1 | Base OS, user, `ufw` default-deny inbound, Docker installed | `docker run --rm hello-world` exits 0 |
| 2 | Redis (agent memory queue) | `redis-cli ping` → `PONG`. **Order matters:** if Redis binds a Docker bridge address, it must start *after* Docker (a systemd drop-in with `After=docker.service`), or it fails on reboot, not on install |
| 3 | Secrets: `.env` on the server, `.env.example` in the repo | `grep -c '^[A-Z_]*KEY=' .env` — names only, never print values |
| 4 | Brain smoke test: one prompt, one completion, from the server | A reply that is not an HTTP 402/429. Fix billing now, not at turn 400 |
| 5 | Speech smoke test: transcribe one clip, synthesise one sentence | Audio plays; measure time-to-first-audio, not just success |
| 6 | Agent worker as a systemd unit | `systemctl is-active` + its health endpoint answers |
| 7 | Tools: start with 2 (`time`, `weather`), not 10 | An agent turn calls the right one and answers from the result |
| 8 | Memory: one SQLite file per person | Turn 1 states a fact, turn 5 recalls it |
| 9 | Surfaces, one at a time: Telegram → PTT → phone | Each surface answers in its own length budget |
| 10 | Private exposure + spoof test (see §6) | From outside the tailnet the port is closed; a forged identity header is rejected |
| 11 | Golden set + baseline report | ~40 items, stored, re-runnable, numbers written down |
| 12 | Backups off-box, encrypted | Restore one file to prove the bundle is readable |

Ship steps 1–8 as a text-only agent before adding any voice surface. Voice doubles the failure modes
(audio path, turn detection, latency) and hides text-path bugs behind them.

---

## 5. Facts that will bite you (learned the hard way)

- **Redis before Docker = boot-time failure, not install-time failure.** Test a reboot.
- **Health servers bind `0.0.0.0` by default** in several voice frameworks. Move them to `127.0.0.1`
  and let the reverse proxy dial loopback. A firewall is not a substitute for binding correctly.
- **`tailscale serve` ≠ Funnel.** Serve exposes to the tailnet; Funnel exposes to the internet. Check
  which one you typed.
- **Never trust an identity header you did not verify.** If your app decides who the user is from a
  proxy header (e.g. `Tailscale-User-Login`), prove that (a) the proxy strips client-supplied copies
  and (b) your server rejects a request carrying two copies. Test both before you tell anyone it is
  ready.
- **A chat platform bot may be served by a different process than you think.** In the reference build
  Telegram was answered by a general-purpose gateway with its own persona file and `language:` setting,
  while a dedicated `telegram_bot` unit sat disabled. Changing the "bot's language" in code did nothing.
  Find the process that actually serves the surface before editing strings.
- **Under a hard budget, measure before you optimise text.** A prompt-optimisation run cost $0.34 and
  found nothing, because the starting prompt already scored 0.98 on the eval — the instrument, not the
  prompt, was the limit. Check that your metric can resolve the effect before you spend on searching.
- **Long turns break first-audio.** Stream speech; do not buffer a whole file. Set a per-turn timeout and
  degrade to text rather than hanging.
- **A tool that cannot answer is worse than a missing tool**, because the model will correctly say "I
  can't confirm" and your human will blame the model. Log per-tool ok-rate and latency, and give the
  model a distinct reason code for "no source" vs "no data".

---

## 6. Security minimums (non-negotiable if a phone or a family uses it)

1. No public inbound port for the agent, the PTT app, or the health endpoints.
2. Secrets only in `.env` on the server; never in git, never in a prompt, never in shell history.
3. One memory store per person; no cross-person reads without that person's consent.
4. A human's ratings are collected only after that human opts in themselves. Do not chase them.
5. Keep an encrypted off-box backup, and prove a restore.
6. Log turns without logging sensitive content; redact utterance text from telemetry.
7. If you expose anything publicly, add real authentication — a private network is the security model,
   not an optional extra.

---

## 7. A lean path (if they only want a chatting agent)

Skip LiveKit, the SIP bridge, the PTT app, and the tailnet: steps 1–5, 7–8, then Telegram only. You
keep memory, tools and the verify-then-answer discipline — roughly a third of the components and
almost none of the audio debugging. Say this out loud to your human early: most people asking for a
"voice agent" want a text agent that can also talk, and the phone-call surface is the expensive 20%.

---

## 8. Where to look in this repo

| Need | File |
|---|---|
| Full rebuild steps + per-step checks | `ops/rebuild/REBUILD.md` |
| The agent loop and tool specs | `agent/` (`loop.py`, `toolspec.py`, `parrot_agent.py`) |
| Prompts, one per language | `prompts/loro_en.md`, `prompts/loro_es.md` |
| Speech backends + install notes | `agent/speech/`, `ops/speech/INSTALL.md` |
| PTT app + serving instructions | `ops/ptt/`, `ops/ptt/SERVE.md` |
| Eval harness, golden sets, bounds | `evals/`, `evals/CONSTRUCTS.md` |
| What shipped, with evidence per criterion | `docs/20_LORO_V1_RELEASE.md` |
| The measured trade-offs behind the defaults | `evals/reports/speech-2026-10.md`, `system-one-2026-10.md`, `gepa-2026-10.md`, `stress-2026-10.md` |
| This project's internal working contract | `AGENTS.md` (not for your human — it is the reference build's own rules) |
