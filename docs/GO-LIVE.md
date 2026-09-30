# GO-LIVE — from bundle to a serving box

This is the short version of `MIGRATION.md`: what the bundle restores **by
itself**, and the exact commands for what it cannot. Written from the real run
on 2026-09-30 (bundle `bundle-20260928-102125`, target `43.173.15.240`).

## The one command

On the new box, as root:

```
cd /srv/vps-plus
sudo ./ops/migrate-golive.sh ~/migrate-bundle --yes
```

That is the whole path. It bootstraps the runtime, restores every archive and
every database, puts the checkouts on their production branches, builds and
starts all four sites, starts the three stacks bootstrap does not know about,
and smoke-tests each domain on loopback. It exits non-zero if anything failed.

If `/srv/vps-plus` does not exist yet (first run, nothing restored), pull the
checkout out of the bundle first:

```
sudo tar --zstd -xf ~/migrate-bundle/archives/srv.tar.zst -C / srv/vps-plus
```

## What the bundle already carries — no configuration needed

| Carried | Where |
|---|---|
| 4 Postgres dumps + MySQL `ojs_local` | `db/` |
| Every nginx vhost (sites-available + sites-enabled) | `etc-system.tar.zst` |
| **All 6 TLS certs** + renewal configs + ACME account | `etc-system.tar.zst` → `/etc/letsencrypt` |
| systemd units: `ojs-queue`, `ojs-scheduler`, `filebrowser`, `mysql.service.d` | `etc-system.tar.zst` |
| AppArmor exception for the custom MySQL datadir | `etc-system.tar.zst` → `/etc/apparmor.d/local/usr.sbin.mysqld` |
| fail2ban jails, cron (root + plus), php-fpm pool | `etc-system.tar.zst` |
| `vps.conf` (domains, ports, repo URLs, `MYSQL_DATABASES`) | `srv.tar.zst` |

Domains are **not** something you re-enter: `vps.conf` travels, the vhosts
travel, the certificates travel. Nothing calls `certbot` on the new box.

## What stays manual — and why

Three things are deliberately not automatic. The first two are decisions, the
third would be actively harmful.

### 1. DNS — the actual cutover

```
cd /srv/vps-plus
./ops/dns.sh --dry-run        # show the plan, change nothing
./ops/dns.sh --apply          # point the A records at the new IP
```

Verify against the **authoritative** nameserver, not `1.1.1.1` — public
resolvers hold the old TTL for up to an hour and will lie to you.

Lower the TTL to 300 **the day before**, not during.

### 2. The Hermes gateway — one bot token, one poller

Two machines polling the same token silently lose Telegram messages. So:

```
# on the OLD box, in a shell that is NOT the gateway:
systemctl --user stop hermes-gateway

# then on the NEW box:
loginctl enable-linger root
XDG_RUNTIME_DIR=/run/user/0 systemctl --user daemon-reload
XDG_RUNTIME_DIR=/run/user/0 systemctl --user start hermes-gateway
```

Do **not** run the first command from inside the agent — SIGTERM propagates and
kills the session that issued it. The tooling blocks it, on purpose.

### 3. What the smoke test cannot tell you

Loopback tests prove nginx, TLS and the backends work. They do not prove the
public path works. After DNS, test through the real internet:

```
for h in www.plusthe.site studio.plusthe.site trilux.plusthe.site \
         ecommerce.plusthe.site office.plusthe.site; do
    printf '%-26s %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' https://$h/)"
done
certbot renew --dry-run
```

## Problems this run actually hit — and the fix

These are real, all six happened, and all six are already handled by
`migrate-golive.sh`. They are listed because if you run the steps by hand
instead, you will meet them.

**1. `useI18n must be used within an I18nProvider` — the `plus` build fails.**
The freeze captured the agents' *working* branches (`agent/consultation-landing`
and friends), which contain unfinished work. Production never had it: the page
returned **404** on the live site. A migration must reproduce production, so
every checkout is moved to the branch `vps.conf` declares (`BRANCH_*`) before
building. If you see this, you are building an agent branch.

**2. `mysql-client absent` and OJS never restores.** `bootstrap.sh` has no MySQL
stage — OJS is not in `APP_KEYS`. `migrate-import.sh` now installs
`mysql-server`, initialises the custom datadir, and starts mysqld itself.

**3. mysqld will not start: `--datadir=/var/lib/mysql-ojs` does not exist.**
The datadir is restored from the dump, not copied, so it has to be created and
initialised first. Both the systemd override and the AppArmor exception travel
in the bundle, but AppArmor needs a reload before mysqld can write there:

```
apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld
install -d -o mysql -g mysql -m 750 /var/lib/mysql-ojs
mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql-ojs
systemctl enable --now mysql
```

**4. `dpkg: end of file on stdin at conffile prompt` — nginx (and anything
else) fails to install.** The bundle restores `/etc` *before* packages are
installed, so every install that ships a config file stops to ask which version
to keep, gets EOF, and dies. The fix is global and one line:

```
cat > /etc/apt/apt.conf.d/99vps-plus-keep-bundle-config <<'EOF'
Dpkg::Options {
   "--force-confdef";
   "--force-confold";
};
EOF
```

Now the bundle's config always wins — which is correct, it is the config the old
box was running. `migrate-import.sh` writes this file for you.

**5. The sites return 502 while every container says `healthy`.** This is not an
nginx problem. `plus`, `studio` and `trilux` answer fine on `127.0.0.1:3000`,
`8080` and `8787`; the 502s are only the three stacks bootstrap does not start:

```
docker compose -f stack/ojs/docker-compose.yml up -d --build      # OJS  :9000
docker compose -f /srv/plus-office/docker-compose.office.yml up -d --build   # :3100
systemctl start ojs-queue ojs-scheduler filebrowser
```

`ecommerce` (fpm `:9001`) lives in `stack/docker-compose.yml` with the other
apps, not in its own repo.

**6. SSH starts refusing connections mid-run.** `ufw limit 22/tcp` rejects more
than ~6 new connections in 30 seconds, and a script that loops over `ssh` per
item trips it. Wait 45 s, then do everything inside **one** connection:

```
ssh host 'bash -s' <<'EOF'
  ...all the commands...
EOF
```

The refusal is rate-limiting, not a dead box — ping still answers.

## Checklist

- [ ] `sha256sum -c checksums.sha256` passes **on the new box**
- [ ] `migrate-golive.sh` exits 0 with `SEMUA HIJAU`
- [ ] every vhost answers on loopback (`--resolve <host>:443:127.0.0.1`)
- [ ] table counts match the dumps: `plusthesite 52`, `ecommerce 38`, `nl 0`, `trilux 0`
- [ ] `ojs_local` has **134** tables and `ojs_app` can log in
- [ ] `certbot renew --dry-run` succeeds
- [ ] DNS lowered to TTL 300 the day before, verified on the authoritative NS
- [ ] **gateway on the old box stopped before the new one starts**
- [ ] old box kept running 3–7 days before it is cancelled
- [ ] `shred -u -r <bundle-dir>` on **both** boxes — it holds plaintext credentials
