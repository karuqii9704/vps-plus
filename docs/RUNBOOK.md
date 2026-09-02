# First migration, step by step

The order matters. DNS propagation and the export both take real time, and
doing them late is what turns a one-hour migration into an evening.

Budget roughly: 15 minutes of your attention spread across the day, plus
40–90 minutes of waiting while things install and build.

---

## Before the VPS exists

### 1. Point DNS first

Do this before anything else — propagation takes 5 minutes to a few hours, and
stage 90 cannot issue certificates until it has finished. You do not have the
VPS IP yet, so this is really "decide the names now, set the records the moment
you have the IP".

Four names, two of which you have not chosen yet:

| app | name | status |
|---|---|---|
| plus | `www.plusthe.site` + `plusthe.site` | decided |
| studio | `studio.plusthe.site` | decided |
| trilux | ? | **you need to pick one** |
| nalar | ? | **you need to pick one** |

An app whose `DOMAIN_*` is empty is skipped entirely — no vhost, no container.
That is a legitimate way to start: bring up two sites now, add the others later
by filling in the domain and re-running stages 70–90.

### 2. Buy the VPS

Ubuntu 24.04 LTS (22.04 also works). KVM 2 if you took that advice; KVM 1 works
but see the note at the end.

Set the four A records to the IP as soon as you have it.

### 3. Export from Windows

Close Hermes and Claude Code first — the export copies SQLite files, and a live
one copies corrupt.

```powershell
cd "F:\VPS Plus"
powershell -ExecutionPolicy Bypass -File .\export\export-from-windows.ps1
```

Expect roughly 45–60 MB (71 skills at ~6 MB, plus a 36 MB `.hub` cache, plus
the vault). If it comes out at 110 MB+, the `.curator_backups` exclusion did
not apply — say so rather than shipping it.

Install `age` first if you want the bundle encrypted at rest:

```powershell
winget install FiloSottile.age
```

---

## On the VPS

### 4. Ship the bundle

```bash
scp vps-plus-bundle.tar.gz.age deploy@<vps-ip>:~/
```

Do this before bootstrapping. Stage 40 looks for it in `~` and skips cleanly if
it is absent — which leaves you with four un-authenticated agents to log into
by hand.

### 5. Clone and configure

```bash
ssh deploy@<vps-ip>
sudo git clone https://github.com/karuqii9704/vps-plus.git /srv/vps-plus
sudo chown -R $USER:$USER /srv/vps-plus
cd /srv/vps-plus
cp vps.conf.example vps.conf
nano vps.conf
```

What actually needs changing in `vps.conf`:

- `DEPLOY_USER` — the user you are logged in as
- `LETSENCRYPT_EMAIL` — a mailbox you read; expiry warnings go there
- `DOMAIN_TRILUX`, `DOMAIN_NALAR` — the two you picked in step 1
- `SWAP_SIZE_GB` — leave at 2 on KVM 2; **set it to 4 on KVM 1**

Everything else has a working default.

### 6. Bootstrap

```bash
sudo ./bootstrap.sh
```

40–90 minutes. Stage 30 (Hermes pulls Python dependencies) and stage 70 (four
container builds, deliberately serial) are the slow ones. Everything is logged
to `/var/log/vps-plus-<timestamp>.log`.

If a stage fails, the run stops and tells you which one. Fix it and resume —
finished stages are stamped and skipped:

```bash
sudo ./bootstrap.sh --force 70
```

### 7. Check it

```bash
ops/status.sh
```

Read three things:

- **endpoints** — green means the container answers locally *and* the public
  URL answers. Yellow means one of the two does not.
- **tls** — days remaining per certificate. A domain missing here had DNS that
  was not ready; fix the record and `sudo ./bootstrap.sh --force 90`.
- **agents** — four versions. `not installed` means that CLI's stage failed;
  `sudo ./bootstrap.sh --force 30`.

Then log out and back in, so `node`, `claude` and `hermes` are on your PATH.

---

## Decisions waiting for you afterwards

### The gateway

Your Telegram and Discord bots are still answering from Windows. Their tokens
are now also on the VPS, but nothing started them there, because two machines
cannot poll one bot token — see `MIGRATION-NOTES.md`.

When you are ready: stop Hermes on Windows, then on the VPS run
`hermes gateway run`. Once that works, write a systemd unit so it survives a
reboot.

### Root SSH

Left enabled on purpose, so a mistake cannot lock you out. Once you have
confirmed you can log in as `$DEPLOY_USER`:

```bash
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl reload ssh
```

Keep the current session open while you test a second one.

### Backups off the box

`ops/backup.sh` writes to the same disk it is protecting, which is a snapshot,
not a backup. Schedule it, then pull the results down:

```bash
sudo crontab -e
# 15 3 * * * /srv/vps-plus/ops/backup.sh >> /var/log/vps-plus-backup.log 2>&1
```

```bash
rsync -avz deploy@<vps-ip>:/srv/data/backups/ ./vps-backups/
```

### MCP servers

`~/.claude.json` still points at Windows paths and was deliberately not
rewritten — guessing produces servers that fail at startup for reasons that
look like Claude Code bugs. Review it when you first need those servers:

```bash
grep -o '[A-Z]:[^"]*' ~/.claude.json | sort -u
```

The remote HTTP ones (exa, github, motion) work untouched.

### If you took KVM 1

Two changes make it comfortable rather than tight:

1. `SWAP_SIZE_GB=4` in `vps.conf` before bootstrapping.
2. Add `output: "standalone"` to NALAR's `next.config.ts`. Its image drops from
   about 1.1 GB to 250 MB and its runtime memory falls with it. That is a change
   in the NALAR repo, not this one.

If builds still hurt, move them off the VPS entirely — build images in GitHub
Actions and have the VPS `docker pull`. That is a real change to
`70-apps.sh` and the compose file, not a config flag.

---

## What has not been tested

Every script here is syntax-checked, and the parts that could be exercised
without a server were: the config helpers, the nginx template rendering, and
the Windows path rewriting against the real `CLAUDE.md` and `config.yaml`.

Nothing has been run on an actual VPS. `apt`, `docker build`, the Hermes
installer and `certbot` have never executed. Expect to hit at least one thing
that needs a fix on the first run — that is what the stage stamps and
`--force` are for.
