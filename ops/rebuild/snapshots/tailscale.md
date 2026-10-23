# Tailscale notes (lorohost)

Captured 2026-10-22 from the VPS (no auth keys, no node keys here).

- Version 1.104.2. Node name `lorohost`, tailnet IPs `100.110.52.38` / `fd7a:115c:a1e0::f436:3427`.
- Joined on 2026-10-22 (plan doc 19 §8). Prefs: `RunSSH=false` (normal sshd on 22 is used), `CorpDNS=false`,
  `ShieldsUp=false`. `tailscale serve` is **not configured yet** (C3 will add it for the PTT app).
- Peers at capture time: owner Mac (`augustos-macbook-pro`), owner iPhone (`iphone-13`).
- Rebuild: `curl -fsSL https://tailscale.com/install.sh | sh`, then `sudo tailscale up --hostname=lorohost`
  and approve the login URL **as the owner** in a browser (interactive; an auth key would be a secret and is
  deliberately not stored). Re-check the tailnet IP afterwards: it will change if the old node is not
  deleted first in the admin console. Everything that names `100.110.52.38` must be updated if it does.
- UFW does not open any Tailscale port; the tailnet is reached over its own interface.
