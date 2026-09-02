# vps-plus

Turns a bare Ubuntu VPS into the machine you already work on: the four AI CLIs
with your own config and memories, four sites served over TLS, and Postgres.

One command does it. Everything specific to you lives in two files — `vps.conf`
for settings, and an encrypted bundle for secrets — so the repo itself carries
no credentials and can be public.

```bash
git clone <this-repo> /srv/vps-plus && cd /srv/vps-plus
cp vps.conf.example vps.conf && nano vps.conf
sudo ./bootstrap.sh
```

## What gets installed

| | |
|---|---|
| **Agents** | Claude Code, Gemini CLI, Codex, Hermes Agent — with your `CLAUDE.md`, `AGENTS.md`, skills vault, memories and logins restored |
| **Sites** | `plusthesite-`, `studio-plusthesite`, `trilux-design-page`, `new-nalar` — cloned, built, containerised, behind nginx with Let's Encrypt |
| **Data** | Postgres 17, one database per app, loopback-only |
| **Runtime** | Docker Engine + Compose, Node 22 via nvm, bun |
| **Host** | ufw (deny inbound except 22/80/443), fail2ban, unattended security upgrades, swap |

New to this? [docs/RUNBOOK.md](docs/RUNBOOK.md) is the ordered checklist for a
first migration, including the parts that have to happen before the VPS exists.

## The three steps

### 1. Export from Windows

Close Hermes and Claude Code first, so nothing is mid-write.

```powershell
powershell -ExecutionPolicy Bypass -File .\export\export-from-windows.ps1
```

This collects, in one bundle:

- **Hermes** — `config.yaml`, all 31 API keys from `.env`, the `auth.json`
  session, `AGENTS.md`, `SOUL.md`, memories, cron, hooks, plugins, the 71
  installed skills, the kanban and project databases, and the gateway's
  Telegram/Discord channel map
- **Claude Code** — `CLAUDE.md`, settings, credentials, commands, agents, skills
- **Gemini CLI** and **Codex** — config and logins
- The **skills vault** from `F:\Claude Work\PROJECTS\AI-Agent-Skills-Vault`
- The four apps' `.env` files

Deliberately left behind: the 370 MB Hermes `state.db` (a live SQLite file
copied while Hermes runs is a corrupt one — pass `-IncludeHermesState` if you
want session history anyway), 68 MB of `.curator_backups` and `.archive` inside
`skills/`, the Windows-only gateway launchers, and `install_id`.

**Do not start the Hermes gateway on the VPS while it is still running on
Windows.** One bot token cannot be polled from two machines — see
[docs/MIGRATION-NOTES.md](docs/MIGRATION-NOTES.md). Stage 40 restores the
credentials but never starts the gateway, so this stays your call.

If `age` is installed (`winget install FiloSottile.age`) the bundle is
encrypted with a passphrase. If not, it is plaintext on disk — `scp` still
encrypts it in transit, but delete it afterwards.

### 2. Ship it

```bash
scp vps-plus-bundle.tar.gz.age deploy@your.vps.ip:~/
```

### 3. Bootstrap

```bash
ssh deploy@your.vps.ip
git clone <this-repo> /srv/vps-plus && cd /srv/vps-plus
cp vps.conf.example vps.conf && nano vps.conf   # domains, mainly
sudo ./bootstrap.sh
```

Stage 40 unpacks the bundle, rewrites the Windows paths inside `CLAUDE.md` and
`AGENTS.md` to their Linux equivalents, then shreds the bundle.

## Stages

`bootstrap.sh` runs `install/*.sh` in order. Each one is idempotent and records
its completion in `/var/lib/vps-plus`, so a re-run resumes instead of starting
over.

| | | |
|---|---|---|
| `00-base` | user, ufw, fail2ban, swap, patches | needs root |
| `10-docker` | Docker Engine + Compose plugin | |
| `20-node` | Node 22 via nvm, bun, corepack | as the deploy user |
| `30-ai-clis` | Claude Code, Gemini, Codex, Hermes | slowest stage |
| `40-restore-config` | unpack the bundle, rewrite paths | skips cleanly with no bundle |
| `50-repos` | clone the four apps | needs `GH_TOKEN` for private repos |
| `60-postgres` | container + per-app databases | generates the password once |
| `70-apps` | build + start the containers | builds serially to avoid OOM |
| `80-nginx` | one vhost per app | prints the DNS records you need |
| `90-tls` | certbot per domain | skips domains whose DNS is not ready |

Run a subset, or force one to repeat:

```bash
sudo ./bootstrap.sh 70 80        # just apps and nginx
sudo ./bootstrap.sh --force 90   # retry TLS after fixing DNS
sudo ./bootstrap.sh --list
```

## Day two

```bash
ops/status.sh              containers, endpoints, cert expiry, disk, agents
ops/deploy.sh plus         pull, rebuild, restart one app
ops/deploy.sh all
ops/logs.sh studio 200     follow a container's logs
ops/psql.sh nalar          a psql shell, no password hunting
ops/backup.sh              pg_dump + config snapshot, 14-day retention
ops/update-agents.sh       update the four CLIs
ops/smoke.sh               open all four sites in a real browser and check them
ops/dns.sh                 point every domain here via the Hostinger DNS API
```

## Layout

```
bootstrap.sh          the entry point
vps.conf              your settings          (gitignored)
lib/common.sh         helpers every stage shares
install/              the ten stages, in order
export/               the Windows-side export script
stack/
  docker-compose.yml  postgres + four apps, all on loopback
  stack.env           generated; holds the Postgres password (gitignored)
  apps/*.env          per-app runtime secrets (gitignored)
  nginx/              the vhost template
apps/
  nalar/Dockerfile    NALAR has none of its own
  trilux/             Express host for Trilux's Vercel-style handlers
ops/                  the day-two scripts
docs/                 the first-migration runbook, secrets handling, and what
                      the move off Vercel actually left unfinished
```

## Things worth knowing before you run it

**DNS first, or stage 90 fails.** Point each domain's A record at the VPS
before bootstrapping. Stage 80 prints the exact records. Stage 90 checks
resolution and skips rather than burning Let's Encrypt's five-failures-per-hour
budget.

**Trilux is not fully off Vercel.** Two of its three API handlers write to
Vercel Blob. They keep working from the VPS with the same token, but the
dependency is still there — see [docs/MIGRATION-NOTES.md](docs/MIGRATION-NOTES.md).

**`NEXT_PUBLIC_*` and `VITE_*` are build-time.** Changing one needs
`ops/deploy.sh <app>`, not a restart. The values are read out of
`stack/apps/<app>.env` and passed as build args, so there is only one copy to
maintain.

**Root SSH is left enabled.** Locking yourself out of a fresh VPS is worse than
the risk it removes. Stage 00 prints the one-liner to disable it once you have
confirmed you can log in as the deploy user.

**Backups sit on the same disk as the data.** `ops/backup.sh` is a snapshot,
not a backup, until you rsync `$DATA_DIR/backups` somewhere else.
