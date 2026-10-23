# REBUILD — Loro / Personal Parrot VPS from git + the backup bundle

Captured from the reference deployment (a 4 GB / 2 vCPU VPS, Ubuntu 24.04.4, kernel
6.8.0-147, 2 vCPU / 3.8 GB / 2 GB swapfile). Everything in this directory is a copy of what ran that day, with
secrets replaced by `${PLACEHOLDER}` names. Values live only in the age bundle and in the `.env` files on the
box. Re-check the date before trusting a file: run the diff in step 13.

Time to rebuild if nothing surprising happens: about 90 minutes, mostly waiting for apt and pip.

## What you need before you start

1. A fresh Ubuntu 24.04 server with a public IPv4 and a `parrot` user (uid 1000, in groups `sudo docker users`;
   NOPASSWD sudo is how it is today; redis dump is read with `sudo cat`). Same `ssh-ed25519` owner key first in
   `~parrot/.ssh/authorized_keys` — **the backup recipient is "the first ssh-ed25519 line", so order matters**.
2. The latest `parrot-backup-*.age` (the Mac pulls them off the VPS; see `docs/18` §6) and the owner's private SSH key
   (`age -d -i ~/.ssh/<owner key>`). Without the key the bundle is unreadable by design.
3. DNS (Porkbun): `parrot.example.com` and `dash.example.com` → the server IP (both A records
   pointed at the same address on 2026-10-22). Twilio Elastic SIP trunk origination URI
   `sip:parrot.example.com:5060` (console-side; not in this repo).
4. This repo (`main` or the release tag).

## What the bundle holds (`agent/backup_nightly.sh`)

Top level: `memory.db`, `dot-env` (= `/home/parrot/parrot/.env`), `livekit.yaml`, `sip.yaml` (with real secrets),
`redis-dump.rdb`, `telemetry.jsonl`.
`hermes/` (= `~/.hermes`) and `hermes-profile-gaston/` (= `~/.hermes/profiles/gaston`): `config.yaml`, `SOUL.md`,
`profile.yaml`, `.env`, `auth.json`, `state.db`, `memories/`, `skills/`, `plugins/`, `cron/`, `price-watches/`.
Excluded on purpose: caches, logs, venvs, `hermes-agent/`, `.curator_backups/`.

**Not in the bundle (gaps — recreate or accept loss):** `~/dashboard/.env` (Twilio SID/token, dashboard logins,
Deepgram management key: re-issue or re-enter), `~/dashboard/feedback.jsonl`, `~/dashboard/BROTHER_LOGIN.txt`,
`~/parrot/events/` (per-call event logs), `~/parrot/inbox/`, `~/.hermes/kanban.db`, the `parrot-*.bak` rollback files.

## Steps (in order; each has a check)

1. **Base packages.** `sudo apt-get update && sudo apt-get install -y redis-server docker.io caddy age python3-venv
   python3-pip ufw sqlite3 curl git ffmpeg ripgrep` (versions on 2026-10-22: `snapshots/versions.txt`). Caddy 2.11.4
   comes from the Caddy apt repo, `docker` 29.x from Docker's repo — match `versions.txt` if the distro is older.
   Install `livekit-server` 1.13.5 to `/usr/local/bin` (GitHub releases of livekit/livekit; plus `lk`,
   `livekit-cli` if you want the CLI). *Check:* `livekit-server --version`.
2. **Firewall first.** Apply `snapshots/ufw-status-numbered.txt`: allow 22/tcp, 80/tcp, 443/tcp, 7881/tcp, 3478/udp,
   50000:60000/udp, 5060/udp, 5060/tcp, 10000:20000/udp (IPv4 and IPv6), default deny incoming, then `sudo ufw enable`.
   Do **not** open 8081 / 8080 / 8090 / 7880 / 6379 (they are loopback or docker-bridge services). *Check:*
   `sudo ufw status numbered` matches the snapshot.
3. **Tailscale.** Follow `snapshots/tailscale.md` (interactive login as the owner; hostname `lorohost`).
4. **Decrypt and unpack the bundle** into a private scratch dir on the new box (or on the Mac, then `scp`):
   `age -d -i ~/.ssh/<owner_key> parrot-backup-<stamp>.tar.gz.age | tar -xz -C /home/parrot/restore`
   (`umask 077`; delete the dir when done). *Check:* `ls /home/parrot/restore` shows the members listed above.
5. **Repo files to `/home/parrot/parrot/`.** Copy `agent/*.py` (+ `agent/goldens/`, `agent/hermes_plugins/`,
   `agent/backup_nightly.sh`, and later `agent/ptt_*`) from the repo. Copy `restore/dot-env` →
   `/home/parrot/parrot/.env` (mode 600) and `restore/memory.db` → `/home/parrot/parrot/memory.db` (mode 600).
   Copy `dashboard/app.py` → `/home/parrot/dashboard/app.py`. `.env` variable names (values not stored here):
   `LIVEKIT_API_KEY LIVEKIT_API_SECRET REDIS_PASSWORD OPENROUTER_API_KEY PARROT_MODEL TOMTOM_API_KEY DEEPGRAM_API_KEY
   BRAVE_API_KEY TELEGRAM_BOT_TOKEN PARROT_IDENTITY_LINKS`. Dashboard `.env`: `DASH_USER DASH_PASSWORD
   DASH_VIEWER_USER DASH_VIEWER_PASSWORD TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN DEEPGRAM_MANAGEMENT_KEY` (recreate by hand).
6. **Python venv.** `python3 -m venv /home/parrot/venv && /home/parrot/venv/bin/pip install -r
   ops/rebuild/snapshots/pip-freeze-venv.txt` (exact versions as of 2026-10-22; `livekit-agents==1.7.0`).
   *Check:* `/home/parrot/venv/bin/python -c "import livekit.agents"`.
7. **Redis.** Merge `redis/redis.conf.effective-subset` into `/etc/redis/redis.conf` (bind `127.0.0.1 172.17.0.1`,
   `appendonly yes`, `maxmemory 256mb`, `requirepass` = `REDIS_PASSWORD` from `.env`). Install the drop-in
   `systemd/redis-server.service.d/10-after-docker.conf` into `/etc/systemd/system/redis-server.service.d/`
   (without it Redis fails to bind docker0 on boot — the 2026-10-22 boot bug). Optionally restore
   `restore/redis-dump.rdb` to `/var/lib/redis/dump.rdb` (owner `redis:redis`) **while Redis is stopped**; if you
   skip it, step 11 recreates the SIP trunk/rule. `sudo systemctl daemon-reload && sudo systemctl enable --now docker redis-server`.
   *Check:* `redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping` → `PONG`; `ss -ltn | grep 6379` shows only the two bind IPs.
8. **LiveKit server.** Create `/home/parrot/livekit/` (mode 775). Take `restore/livekit.yaml` and `restore/sip.yaml`
   (real values) — or fill `livekit/livekit.yaml` and `livekit/sip.yaml` from this directory by substituting
   `${REDIS_PASSWORD}`, `${LIVEKIT_API_KEY}`, `${LIVEKIT_API_SECRET}` from `.env` — into that directory, mode 600.
   Install `systemd/livekit-server.service`. *Check:* `systemctl is-active livekit-server`, `ss -ltn | grep 7880`
   → `127.0.0.1:7880` only.
9. **livekit-sip container** (host network, pinned image digest in `snapshots/sip-container.txt`):
   `docker run -d --name livekit-sip --restart unless-stopped --network host
   -v /home/parrot/livekit/sip.yaml:/sip/config.yaml livekit/sip@sha256:<digest from snapshot>`.
   *Check:* `docker ps` shows `Up`; SIP listens on 5060.
10. **Caddy.** Copy `caddy/Caddyfile` → `/etc/caddy/Caddyfile`, `sudo systemctl reload caddy`. Certificates are
    issued on first request (needs ports 80/443 and the DNS from "before you start"). *Check:*
    `curl -sI https://parrot.example.com/ | head -1` (any HTTP status = TLS works).
11. **Parrot units.** Copy `systemd/parrot-*.service`, `parrot-backup.timer` and the drop-ins
    (`parrot-agent.service.d/{limits,umask}.conf`, `parrot-memory-worker.service.d/umask.conf`) into
    `/etc/systemd/system/`. `sudo systemctl daemon-reload && sudo systemctl enable --now parrot-agent
    parrot-memory-worker parrot-dashboard parrot-telegram parrot-backup.timer parrot-sip-bootstrap`.
    *Check:* `journalctl -u parrot-agent -n 30 | grep "registered worker"` within ~20 s; the worker health server is on
    `127.0.0.1:8081` once the C1 bind change (`WorkerOptions(host="127.0.0.1")`) is deployed, otherwise `0.0.0.0:8081`.
    Known quirk on 2026-10-22: `parrot-sip-bootstrap.service` showed `failed` while calls still worked; read its
    journal before assuming the trunk is healthy (`lk sip inbound list`).
12. **Hermes gateway (user unit, linger on).** `sudo loginctl enable-linger parrot`. Install the Hermes Agent
    (v0.21.0 on 2026-10-22, upstream `NousResearch/hermes-agent`, running checkout `63279301` = upstream `ee445299`
    **plus one carried local commit** — a fresh clone of upstream will not have that commit) into
    `~/.hermes/hermes-agent` with its own venv. Restore `restore/hermes/*` → `~/.hermes/` and
    `restore/hermes-profile-gaston/*` → `~/.hermes/profiles/gaston/` (modes: dirs 700, secrets 600). Copy
    `systemd-user/hermes-gateway.service` → `~/.config/systemd/user/`, then `systemctl --user daemon-reload &&
    systemctl --user enable --now hermes-gateway`. *Check:* `systemctl --user is-active hermes-gateway`; Gaston's
    Orbea cron job appears in `~/.hermes/profiles/gaston/cron/jobs.json`.
13. **Acceptance.** Run the live self-test (`agent/live_selftest.py`), place one real call, send one Telegram message.
    Then re-diff this directory against the new box:
    `for f in $(cd ops/rebuild/systemd && ls *.service *.timer); do diff <(ssh lorohost cat /etc/systemd/system/$f) ops/rebuild/systemd/$f; done`.

## Facts a rebuilder would otherwise trip on

- Nightly bundle = `parrot-backup.timer` 09:00 UTC → `/home/parrot/backups/parrot-backup-<UTC>.tar.gz.age`, 7 kept.
  Dry-run (no encryption, prints the member list): `BACKUP_DRY_RUN=1 /home/parrot/parrot/backup_nightly.sh`.
  Test run to another path: `BACKUP_OUT=~/staging/x/test.tar.gz.age /home/parrot/parrot/backup_nightly.sh`.
- Caddy proxies **public** `https://parrot…/health*` to the worker health server on `localhost:8081` (returns 404 today),
  and the dashboard on `localhost:8090` is public behind its own login. The raw ports are firewalled; loopback-only
  binding (`host="127.0.0.1"`) does not affect Caddy because it talks to `localhost`.
- `livekit-sip` health listens on `*:8080` (firewalled).
- No user crontab on the VPS (`snapshots/crontab-parrot.txt`); no `tailscale serve` yet (C3 adds it).
- `parrot-backup` also depends on `age`, `redis-cli` and passwordless `sudo cat /var/lib/redis/dump.rdb`.

## Secret hygiene for this directory

`ops/rebuild/scan_secrets.sh` (patterns are in the script, not here, so this file does not match itself) greps every
file for key-shaped strings after stripping `${PLACEHOLDER}` tokens and public docker image digests. It must print
nothing and exit 0 before any commit under `ops/`. `pip-freeze-venv.txt` is excluded (package pins only).
