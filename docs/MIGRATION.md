# Migrating this VPS

Everything needed to move this machine to a new one, without forgetting the
parts that are not automated.

Two routes exist. **Route A is both faster and safer** — the numbers below come
from measuring this box, not from a blog post.

| | Route A — rebuild + restore | Route B — clone the root filesystem |
|---|---|---|
| transfer | ~3 GB | ~15 GB (no docker) or ~73 GB (with docker) |
| build cache / images | rebuilt on the new box | either re-pulled, or 58 GB of overlay2 copied |
| app images | rebuilt (fresh, 15–30 min) | **still rebuilt** — layers live in `/var/lib/docker` |
| resumable | yes — `bootstrap.sh` stamps every stage | no, a broken run means starting over |
| hand-fixes | none | netplan, hostname, machine-id, monarx re-register, ufw re-apply |
| est. working time | **2–3 h** | 3–5 h |
| est. real downtime | **15–30 min** | 15–30 min (same) |

Route B has no advantage: the 58 GB it adds (38 GB build cache + 20 GB images)
is regenerated in about 15 minutes, and the app images still have to be built
because overlay2 layers are not portable in practice.

Almost all of Route A happens **while the old box keeps serving**. Only the
final delta sync, the gateway switch and the DNS change are downtime.

---

## Phase 0 — before you buy anything

Do these on the OLD box. They make the migration boring.

1. **Lower the DNS TTL to 300s** and wait for the old TTL to expire
   (`ops/dns.sh`, or the registrar panel). A 1800s TTL turns a 5-minute cutover
   into a 30-minute one.
2. **Take a real off-box backup.** The nightly job writes to the same disk as
   the data it protects.
   ```
   ops/backup.sh
   rsync -avz plus@<old-ip>:/srv/data/backups/ ./vps-backups/
   ```
3. **Push every repo.** Uncommitted work in a checkout is the single most
   common thing lost in a migration. The export records what is dirty —
   read `meta/git-state.txt` inside the bundle, then push.
4. **`/srv/ojs-qa`** (the QA staging instance: dead containers, orphaned MySQL
   volume) is preserved automatically as its own archive. Its client reports,
   audit scripts and E2E harness travel; the OJS checkouts inside do not
   matter because they are re-clonable. Restore it with `--with-ojs-qa`, or
   drop it from the bundle with `--skip-ojs-qa`.

## Phase 1 — build the bundle (old box)

```
cd /srv/vps-plus
./ops/migrate-export.sh --dry-run     # look at the plan + real sizes first
./ops/migrate-export.sh               # ~3 GB into $DATA_DIR/migrate/bundle-<stamp>
```

Flags, and what they cost:

| flag | effect |
|---|---|
| `--include-build` | keep `node_modules`/`.next`/`dist`/`vendor` (+ ~1.4 GB) |
| `--skip-ojs-qa` | omit `/srv/ojs-qa` entirely |
| `--include-old-backups` | keep `$DATA_DIR/backups` archives (+ 3.3 GB) |
| `--keep-ojs-logs` | keep OJS `scheduledTaskLogs` + `usageStats` (+ 366 MB of log) |
| `--lean` | also drop `.local`, `.claude`, `.gemini`, `bec-bundle` |

`/srv/ojs-qa` is always packaged as its **own** archive (`ojs-qa.tar.zst`,
312 MB compressed) rather than folded into `srv.tar.zst`, so the main restore
never pays for it. `migrate-import.sh` only unpacks it with `--with-ojs-qa`.
The QA harness inside is worth keeping — client reports, audit scripts, the
Playwright E2E suite — while its `ojs/`/`ojs-git/` checkouts are re-clonable.

The bundle contains **plaintext credentials**. It is written mode 700; keep it
that way.

Verify it before trusting it. Two levels — the cheap one checks the checksums,
the thorough one actually unpacks every archive and hashes the result against
the live source:

```
# cheap: is the bundle internally intact?
./ops/migrate-export.sh --verify /srv/data/migrate/bundle-<stamp>

# thorough: is it a faithful copy of this box? (~6 min, needs ~5 GB in /tmp)
./ops/migrate-verify-bundle.sh /srv/data/migrate/bundle-<stamp>
```

`migrate-verify-bundle.sh` unpacks into `/tmp/restore-sim` and compares every
file byte-for-byte. Files under known live-write paths (`.claude`, `.hermes`,
`srv/hq/status`, `*/​.git/index`) are classified as expected drift — agents and
the gateway rewrite them continuously — and anything else is reported as a real
finding. A non-zero table count in a Postgres dump is **not** required: two of
the four app databases here are legitimately empty, so the script only fails a
dump that is not a replayable `pg_dump`/`mysqldump` stream.

Then push it:

```
./ops/migrate-export.sh --verify /srv/data/migrate/bundle-<stamp>
/srv/data/migrate/bundle-<stamp>/transfer.sh root@<new-ip>
```

`transfer.sh` runs `rsync` and then re-checks the sha256 sums on the far side.

## Phase 2 — bring the new box to the starting line

New VPS: Ubuntu 24.04, x86_64, **at least the same RAM/CPU as the old one**
(this box runs ollama, so 8 GB / 2 vCPU is the floor).

`ops/migrate-import.sh` is an untracked file — it only exists on the old box
until it is committed and pushed. Either push it first:

```
# on the OLD box, as the deploy user
cd /srv/vps-plus
sudo -u plus git add ops/migrate-*.sh ops/backup.sh vps.conf.example docs/MIGRATION.md
sudo -u plus git commit -m "add migration tooling + MySQL to the nightly backup"
sudo -u plus git push
```

…or take the whole checkout out of the bundle instead of cloning:

```
tar --zstd -xf ~/migrate-bundle/archives/srv.tar.zst -C / srv/vps-plus
```

Then:

```
apt-get update && apt-get install -y git
git clone https://github.com/karuqii9704/vps-plus.git /srv/vps-plus
cd /srv/vps-plus
# vps.conf is gitignored on purpose — it travels in the bundle
tar -xzf ~/migrate-bundle/archives/srv.tar.zst -C / srv/vps-plus/vps.conf
./bootstrap.sh 00-base 10-docker 20-node
```

## Phase 3 — restore data

```
cd /srv/vps-plus
./ops/migrate-import.sh ~/migrate-bundle --only files,system
./bootstrap.sh 60-postgres
./ops/migrate-import.sh ~/migrate-bundle --only db
./bootstrap.sh 70-apps 80-nginx 90-tls
./ops/migrate-import.sh ~/migrate-bundle --only ownership,verify
```

`migrate-import.sh` is not a whole migration — it restores **data and config
only**. The runtime (docker, node, images, containers, vhosts, TLS) is built by
`bootstrap.sh`. That is why the two are interleaved.

Phases, in the order they must run:

- `files` — `/srv`, the deploy home, `/root/.hermes`, the OJS web tree
- `system` — nginx, TLS, AppArmor, systemd, docker, fail2ban, crontab
- `db` — every Postgres database + the MySQL OJS database
- `ownership` — owners and modes (see the trap below)
- `verify` — asserts the result and lists what is still missing

### What the bootstrap does NOT know about

`bootstrap.sh`'s stages cover `plus`, `studio`, `trilux`, `nalar` and
`ecommerce`. These four run on this box and are **not** covered by any stage —
start them by hand:

```
docker compose -f stack/ojs/docker-compose.yml up -d --build
systemctl start mysql ojs-queue ojs-scheduler

docker compose -f apps/supabase.compose.yml \
    --env-file apps/supabase/supabase.env up -d

# plus-office (ollama): re-pull the image; its 2 GB model volume is not in the bundle
```

## Phase 4 — cutover

Order matters. Doing these out of order causes avoidable breakage.

1. **Final delta sync** while the old box still serves:
   ```
   rsync -avz --delete-after plus@<old-ip>:/srv/ /srv/     # adjust excludes
   ```
2. **Stop the gateway AND the autonomous agents on the OLD box.** One bot token
   = one poller; two machines polling the same token means silently lost
   Telegram messages.
   ```
   hermes gateway stop                  # on the OLD box — do this FIRST
   pkill -f '/srv/hq/run-agent.sh'      # the HQ agents write to the repo
                                        # checkouts continuously
   ```
   While the agents run, the working trees never stop changing: a bundle or an
   rsync is always chasing a moving target, and uncommitted agent work is the
   easiest thing to lose in a migration. Stop them, then **commit and push
   every checkout** — the verify step reports exactly which repos are dirty and
   on which branch:
   ```
   cd /srv/vps-plus && ./ops/migrate-verify-bundle.sh <bundle>
   ```
   Any line saying `PUSH BEFORE MIGRATING` has to be resolved before the
   cutover, not after.
3. **DNS**: point the A records at the new IP.
   ```
   ops/dns.sh --dry-run       # compare the plan against this list before applying
   ops/dns.sh --apply
   ```
   Verify on the **authoritative** nameserver, not `1.1.1.1` — public resolvers
   keep the old TTL, the VPS's own resolver is instant.
   ```
   dig @ns1.<provider> www.plusthe.site +short
   ```
4. **TLS**: the certs came over in `etc-system.tar.zst`. Prefer them over
   re-issuing — Let's Encrypt allows 5 duplicate certificates per week.
   ```
   certbot renew --dry-run
   ```
5. **Start the gateway on the new box** and confirm it reconnects:
   ```
   hermes gateway start
   ```
6. **Smoke test every vhost** through public HTTPS, not loopback:

| host | what to check |
|---|---|
| www.plusthe.site | 200, login, lead/contact write |
| studio.plusthe.site | 200 |
| trilux.plusthe.site | 200, assets/fonts cached |
| ecommerce.plusthe.site | 200, product page, checkout path |
| testojs.plusthe.site | 200, login, submission flow, theme CSS compiles |
| office.plusthe.site | 200 |

`ops/smoke.sh` covers the APP_KEYS apps; OJS needs the E2E recipe in
`references/ojs-e2e-http.md`.

## Phase 5 — keep the old box

Do **not** delete it. Leave it powered off but intact for 3–7 days:

- DNS has stale caches in the wild for a while
- TLS renewal, queue workers and cron jobs may still be scheduled against it
- the old box is the rollback

Once the new box has run for a week with a green `ops/backup.sh`, then destroy
the old one.

**Shred the bundle on both boxes** when you are done — it is plaintext
credentials:
```
shred -u -r /srv/data/migrate/bundle-<stamp>
```

---

## Traps specific to this box

Each of these has bitten before or is one keystroke from doing so.

### MySQL, not Postgres, holds OJS

`ops/backup.sh` dumped only Postgres until 2026-09-28, so `ojs_local` had **no
dump at all** — the live datadir was the only copy. The script now dumps MySQL
too (`MYSQL_DATABASES` in `vps.conf`). Verify after any edit:
```
sudo -u plus /srv/vps-plus/ops/backup.sh --keep 14 && ls -la /srv/data/backups | grep ojs
```

### The MySQL datadir lives outside `/var/lib/mysql`

`/var/lib/mysql-ojs` with a systemd override *and* an AppArmor exception. Miss
the AppArmor file and mysqld abort-loops with `errno 13 — Permission denied` on
a file that exists with correct ownership. That is an AppArmor denial, not a
filesystem one — check `aa-status`, not `chmod`.

Both files travel in `etc-system.tar.zst`; `migrate-import.sh --only system`
reloads the profile.

### `config.inc.php` is not in git, and mode 600 locks the site out

The container runs as uid 33. The file must be `plus:www-data` mode **640** —
mode 600 gives an empty page with no error anywhere.

### The OJS bind mount must be at the identical absolute path

`stack/ojs/docker-compose.yml` mounts `/var/www/biadenrekacipta/ojs` at the
same path *inside* the container, because nginx sends an absolute
`SCRIPT_FILENAME`. A different path on the new box means every request 404s.

### The OJS application user is not in any dump

`mysqldump --databases` never emits `CREATE USER`. `migrate-import.sh` recreates
`ojs_app@127.0.0.1` by reading the credentials out of `config.inc.php`, which
does travel with the bundle. If that parse fails, create it by hand and grant
`ALL PRIVILEGES ON ojs_local.*`.

### New permissions on `vps.conf`

`SRV_ROOT` is the **repo checkout itself** (`/srv/vps-plus`), not the directory
that holds it. `REPOS_DIR` and `DATA_DIR` are separate absolute paths that
happen to share the parent `/srv`. `migrate-export.sh` now derives the tree it
packs from `dirname SRV_ROOT` and refuses to run if the three disagree.

### Rebuilds are safe — with two caveats worth pinning down

Everything the five app images need travels in the bundle: the Dockerfiles
(`apps/trilux/`, `apps/nalar/`, `stack/ecommerce/`, `stack/ojs/`, and the two
that live in their own repos), every `package-lock.json` / `composer.lock`, and
the build-time env files (`stack/apps/*.env` — `NEXT_PUBLIC_*`/`VITE_*` are
inlined into the bundle at build time, so they must be present *when building*,
not just at runtime). A cold `docker build --no-cache` of the trilux image was
measured at **15 seconds**, so dropping the 38 GB cache costs minutes, not
hours.

Two things can still bite a rebuild months later:

1. **Floating base tags.** `node:22-alpine`, `php:8.3-fpm`, `php:8.4-fpm`,
   `postgres:17-alpine` move upstream. `meta/image-digests.txt` inside the
   bundle records the exact digests this box was built against — pull those by
   digest first if you need the new box to match.
2. **Unpinned apt packages** in the PHP images (`apt-get install -y
   --no-install-recommends …` has no versions). Debian keeps bookworm stable, so
   this is usually fine, but it is the least reproducible step in the chain.

Apps that pin their dependency graph with `npm ci` (plus, studio, nalar,
ecommerce, and trilux since 2026-09-28) rebuild deterministically. Anything
using plain `npm install` does not — check before trusting a rebuild.

### Root-owned files inside `.git`

A single root-owned write into a checkout makes every later
`sudo -u plus git ...` fail with a confusing permission error. Check before
committing:
```
find /srv -path '*/.git/*' -user root
```
`migrate-import.sh --only ownership` fixes them.

### Never blanket-chown the ecommerce checkout

`chown -R <deploy>:<deploy> /srv/repos/ecommerce` breaks the app. Its container
runs as **uid 33**, so:

- `storage/` and `bootstrap/cache/` must be `www-data:www-data` (the app writes
  sessions, logs, cache and uploads there)
- `.env` must be `<deploy>:www-data` mode **640** — mode 600 or a group of
  `<deploy>` locks the app out

This fails **silently**. The site keeps answering **HTTP 200**, because Laravel
boots from the cached `bootstrap/cache/config.php` and never opens `.env`; the
breakage only surfaces on the next container restart or `config:clear`. Prove it
from inside the container, as the app's uid — never as root:

```
docker exec vpsplus-ecommerce-fpm sh -c \
  'head -c1 /srv/repos/ecommerce/.env >/dev/null && echo read-ok;
   touch /srv/repos/ecommerce/storage/logs/.wtest && rm /srv/repos/ecommerce/storage/logs/.wtest && echo write-ok'
```

`migrate-import.sh --only ownership` blanket-chowns `/srv` and then re-applies
these two settings; `--only verify` asserts them.

### The Supabase stack needs its roles first

`plusthesite` carries the `auth` and `storage` schemas, but the roles that own
them (`authenticator`, `supabase_auth_admin`, …) live outside any dump. The
import applies `apps/supabase/roles.sql` before the restore. Without it the
restore fails on ownership.

### PostgREST caches the schema

After any restore or DDL, `docker restart vpsplus-supabase-rest`. A reload is
not enough — it re-reads config, not the schema.

### Verify a firewall from outside the box

Connecting to your own public IP from the same host never traverses the `ufw`
INPUT chain, so a local scan reports every bound socket as open. Use
`check-host.net/check-tcp` or another vantage point.

After any stage that re-applies ufw, re-allow manually added ports — and make
sure 9090 (Cockpit) is **not** one of them. Loopback plus an SSH tunnel only:
```
ssh -L 9090:127.0.0.1:9090 plus@<ip>
```
