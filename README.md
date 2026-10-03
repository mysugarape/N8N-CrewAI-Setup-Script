# n8n & CrewAI Setup Script (Debian 12 / aaPanel)

An interactive, idempotent Bash script that sets up a complete n8n installation with a PostgreSQL database as well as a CrewAI/FastAPI microservice on a **Debian 12** server running **aaPanel** — both kept alive across reboots via systemd and PM2 respectively.

[![Shell](https://img.shields.io/badge/shell-bash-blue.svg)](https://www.gnu.org/software/bash/)
[![Debian](https://img.shields.io/badge/debian-12-red.svg)](https://www.debian.org/)

Repository: [github.com/mysugarape/N8N-CrewAI-Setup-Script](https://github.com/mysugarape/N8N-CrewAI-Setup-Script)

---

## Contents

- [What the script does](#what-the-script-does)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
  - [Phase 3 — three checks and one backup](#phase-3--three-checks-and-one-backup)
  - [Phase 4 — Enter your API key (required)](#phase-4--enter-your-api-key-required)
  - [If phase 7 aborts](#if-phase-7-aborts)
- [Manual steps in aaPanel after installation](#manual-steps-in-aapanel-after-installation)
- [Credentials](#credentials)
- [Pinned versions](#pinned-versions)
- [Important environment variables](#important-environment-variables)
- [Day-to-day commands](#day-to-day-commands)
- [Security notes](#security-notes)
- [Behaviour on a re-run](#behaviour-on-a-re-run)
- [Troubleshooting](#troubleshooting)
- [Project structure](#project-structure)

---

## What the script does

The script runs seven steps in one continuous, error-tolerant session:

| Step | Content |
|------|---------|
| **1. Pre-check** | Verifies root privileges and required tools (`openssl`, `curl`), then asks whether aaPanel and the PostgreSQL Manager are already present |
| **2. Configuration** | Asks for the subdomain, generates passwords and the `N8N_ENCRYPTION_KEY` |
| **3. System** | Sets up 4 GB of swap, installs system packages, PostgreSQL, Node.js LTS and Python 3 |
| **4. Database** | Sets the PostgreSQL superuser password and creates the database, user and grants |
| **5. n8n** | Installs n8n, writes a PM2 ecosystem file, starts the service and enables autostart on boot |
| **6. CrewAI** | Creates a venv, installs CrewAI/FastAPI/uvicorn, writes a sample API and registers it as a systemd service |
| **7. Summary** | Writes all credentials to a root-only file and lists the versions |

### Configuration files created by the script

```
/swapfile                                  4 GB of swap
/etc/systemd/system/crewai.service         systemd unit for the FastAPI service
/opt/agent_service/main.py                 sample API with one CrewAI agent
/opt/agent_service/.env.example            template for API key and model
/opt/agent_service/venv/                    Python virtualenv
/var/lib/crewai/                           writable service data (SQLite)
/root/n8n/ecosystem.config.cjs             PM2 config with all n8n variables
/root/n8n-setup-credentials.txt            credentials (readable by root only)
```

In addition, an unprivileged system user `crewai` is created (UID from the system range, no login shell), and the agent service runs as that user. Unlike root, it cannot be used interactively:

```bash
id crewai          # uid=..., no-create-home, shell /usr/sbin/nologin
```

> **Why `/opt` and not `/var/www`:** `/var/www` is aaPanel's typical website root. A `.env` holding the API key would sit inside the web root and could be served as plaintext. `/opt` lives outside it and is FHS-conformant for services.

---

## Prerequisites

- **Operating system:** Debian 12 (Bookworm) — other distributions are not tested
- **aaPanel:** must already be installed and running
- **PostgreSQL Manager in aaPanel:** must be installed from aaPanel's App Store — **the manager only, not the database itself** (see the note below)
- **Root privileges:** the script writes system files and starts services
- **Network access** for `apt`, NodeSource and npm
- **Roughly 10 GB of disk space** (swap, PostgreSQL, node modules, Python venv)

### PostgreSQL Manager via aaPanel

Before running the setup, install the **manager itself** under **aaPanel → App Store → PostgreSQL Manager**. Do **not** pick a PostgreSQL version and do not let it create a database — the script does both afterwards:

- installing the PostgreSQL server via `apt-get install postgresql`
- setting the password of the superuser `postgres`
- creating the database `n8n_db`, the user `n8n_db` and its grants

> **Why only the manager?** If you install a PostgreSQL version from the App Store, aaPanel sets up its own, divergent installation. The script would then run `systemctl enable --now postgresql` against a service that aaPanel manages, and the two configurations drift apart. Installing only the manager keeps aaPanel as the administrative front end while the actual server comes from the script.
>
> **After installation:** the manager in aaPanel can be used to manage the database, create backups and inspect logs. To keep the service under systemd rather than aaPanel, do not change the PostgreSQL version in the App Store.

> **Note:** on a fresh Debian 12 with less than 4 GB of RAM the swap file is mandatory, because PostgreSQL and n8n otherwise end up in the OOM killer during startup.

---

## Installation

The installation has four phases: aaPanel, the script itself, the API key, and finally the manual steps in aaPanel. Do not skip ahead — the script checks phase 1 and aborts without it.

### Phase 1 — aaPanel (before running the script)

1. Install aaPanel including its Nginx stack, and wait until the panel is reachable in the browser.
2. Under **aaPanel → App Store → PostgreSQL Manager**, install the **manager only**. Do not install a PostgreSQL version and do not let it create a database.
3. Leave the website, SSL and reverse proxy alone for now — that is phase 4.

### Phase 2 — the script

#### 2.1 Clone the repository

```bash
git clone https://github.com/mysugarape/N8N-CrewAI-Setup-Script.git
cd N8N-CrewAI-Setup-Script
```

#### 2.2 Run it

```bash
sudo bash setup.sh
```

The script is **fully interactive** and asks four questions:

```
1. Is aaPanel already fully installed on this server? (y/n) [n]:
2. Is the PostgreSQL Manager installed in aaPanel? (manager only) (y/n) [y]:
   → domain prompt:    Subdomain for n8n [default: n8n.formhabr.com]:
   → confirmation:    Do you want to start the installation now? (y/n) [y]:
```

> **Tip:** every prompt can be confirmed with **Enter** to accept the default. The script also works without a TTY — missing input then falls back to the defaults (useful for CI).

#### 2.3 What happens while it runs

| Output marker | What is going on |
|---------------|------------------|
| `1. Prüfung der Voraussetzungen` | Root check, tools, aaPanel and PostgreSQL Manager |
| `2. System-Pakete, Swap & Node.js` | 4 GB swap, `apt`, Node.js LTS via NodeSource |
| `3. PostgreSQL Admin-Passwort …` | Superuser password, database `n8n_db`, user, grants |
| `4. PM2 & n8n (v2.41.6) installieren` | The longest step: full download of the node modules |
| `5. n8n PM2 Service konfigurieren & starten` | `ecosystem.config.cjs`, PM2 process, autostart |
| `6. CrewAI venv, FastAPI & systemd Service` | venv, `pip install crewai[anthropic]`, `main.py`, unit |
| `7. Systemd Service für CrewAI erstellen & starten` | Start plus a wait loop for port 8000 |

Expect **10 to 25 minutes** in total. The npm download and the compilation of the Python dependencies dominate.

#### 2.4 The final verification

Phase 7 does not simply trust `systemctl start`. It polls for up to 60 seconds until something listens on port 8000, and aborts if the service dies in the meantime — because `systemctl restart` exits 0 even when the process dies immediately afterwards. A successful run therefore means **both** services were verified, not merely started.

#### 2.5 Result

On success the script prints a summary:

```
==========================================================
 SETUP COMPLETED SUCCESSFULLY!
==========================================================
INSTALLED VERSIONS:
 - Node.js:            v24.21.0
 - npm:                10.x.y
 - n8n:                2.41.6
 - crewai / fastapi:   1.15.23 / 0.142.2
 - uvicorn:            0.53.0
----------------------------------------------------------
CREDENTIALS:
 - n8n domain:         https://n8n.formhabr.com
 - CrewAI endpoint:    http://127.0.0.1:8000
----------------------------------------------------------
GENERATED PASSWORDS — keep these safe:
 - Postgres admin ('postgres'):   <generated password>
 - Database user (n8n_db):       <generated password>
 - N8N_ENCRYPTION_KEY:            <generated key>
 - Database name:         n8n_db
 - CrewAI service user:   crewai (unprivileged, no login)
----------------------------------------------------------
REQUIRED FOR THE CREWAI SERVICE:
Without an API key /run-agent returns a 500.
   cp /opt/agent_service/.env.example /opt/agent_service/.env
   nano /opt/agent_service/.env
   chown root:crewai /opt/agent_service/.env
   chmod 640 /opt/agent_service/.env
   systemctl restart crewai
----------------------------------------------------------
CAUTION: these passwords are now in your terminal scrollback
and in any logs if the output was redirected. Keep the
credentials file safe and do not delete it:
   /root/n8n-setup-credentials.txt
   cat /root/n8n-setup-credentials.txt
```

*(The npm version depends on the npm 10 release available at install time and may vary. The passwords are shown as placeholders here.)*

### Phase 3 — three checks and one backup

Run these directly after the summary. Only the first one changes anything; the other two are verifications.

```bash
# 1. Copy the credentials out of /root — they are gone if the server is rebuilt
cp /root/n8n-setup-credentials.txt ~/n8n-credentials-backup.txt

# 2. Check: the .env must be root:crewai 640
ls -la /opt/agent_service/.env

# 3. Check: all three services must survive a reboot
systemctl is-enabled crewai postgresql pm2-root
```

**Why each one matters**

- **Backup** — the credentials live only under `/root`. That directory does not survive a reinstall, and `N8N_ENCRYPTION_KEY` cannot be recovered anywhere else. Keep the copy outside the server as well.
- **`.env` rights** — with `600` and owner root the service, running as `crewai`, can no longer read the key and every request fails with a 500.
- **`is-enabled`** — if any of the three prints `disabled`, nothing comes back after a reboot. Fix with `systemctl enable <name>`.

### Phase 4 — Enter your API key (required)

The setup is **complete** at this point, but the agent service cannot answer any request yet. The script deliberately only writes a template — an API key committed to the source would end up permanently in the git history.

```bash
cp /opt/agent_service/.env.example /opt/agent_service/.env
nano /opt/agent_service/.env                 # ANTHROPIC_API_KEY=sk-ant-...
chown root:crewai /opt/agent_service/.env    # the service's group must be able to read it
chmod 640 /opt/agent_service/.env            # NOT 600 — see below
sudo systemctl restart crewai
```

> **Why `640` and not `600`:** the service runs as the system user `crewai`, not as root. With `600` and owner root it would no longer reach the key, and every request would fail with a 500. `root:crewai 640` means: root may do anything, the `crewai` group may read, and no other user on the server may.

Confirm the service came back up before you spend tokens:

```bash
systemctl is-active crewai
ss -ltn | grep :8000
```

Verify the key without printing it:

```bash
cd /opt/agent_service && ./venv/bin/python -c "
import main, os
k = os.getenv('ANTHROPIC_API_KEY') or ''
print('Key set:   ', bool(k))
print('Placeholder:', k == 'sk-ant-enter-key-here')
print('Model:     ', main._build_llm().model)
"
```

Then the first real run (costs tokens). The first request takes **30 to 90 seconds** — the model is cold and the `.pyc` files are generated on the fly. Do not cancel it:

```bash
curl -sX POST http://127.0.0.1:8000/run-agent \
  -H 'Content-Type: application/json' \
  -d '{"topic":"Advantages of n8n"}' | python3 -m json.tool
```

A correct response looks like this:

```json
{
    "status": "success",
    "model": "anthropic/claude-haiku-4-5",
    "result": "n8n is a workflow automation tool ...",
    "usage": {
        "prompt_tokens": 1234,
        "completion_tokens": 456,
        "total_tokens": 1690
    }
}
```

`usage.total_tokens` must be **greater than 0**. If `result` contains text but the token count is 0, the agent never actually ran.

### If phase 7 aborts

```
[ABBRUCH] Der CrewAI-Service lauscht nicht auf Port 8000.
```

This is the verification working as intended — it reports a real failure instead of a false success. n8n and PostgreSQL are already running at that point and are not affected. Get the actual error first:

```bash
journalctl -u crewai -n 40 --no-pager
```

To determine whether the code or the unit is at fault, start the service outside systemd:

```bash
cd /opt/agent_service
sudo -u crewai env HOME=/var/lib/crewai \
  ./venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
```

If that works, the unit's sandboxing is too strict — the known case is crewai's storage path. The unit handles it with `Environment=CREWAI_STORAGE_DIR` and `Environment=HOME`; if those are missing from your unit, add them via `systemctl edit crewai`.

---

## Manual steps in aaPanel after installation

The script configures the services, **not** the reverse proxy and **not** SSL. You have to do these steps yourself in aaPanel:

1. **Create a website** — under *Websites*, create a website for your subdomain.
2. **Enable SSL** — under *SSL*, issue a Let's Encrypt certificate and turn on **Force HTTPS**.
3. **Set up the reverse proxy** — forward to `http://127.0.0.1:5678`.

> **Important:** n8n deliberately listens on `127.0.0.1` only (see `N8N_LISTEN_ADDRESS`). **As long as the reverse proxy is not configured, n8n is unreachable.** That is intentional: the port is never exposed to the internet unprotected.

Optionally, you can add a second reverse proxy in the same panel pointing at `http://127.0.0.1:8000` for the CrewAI service.

### First n8n login

On the first visit to n8n you create an owner account. **You choose those credentials yourself** — the script does not generate them.

---

## Credentials

The generated passwords are **printed at the end of the setup** and additionally stored permanently in a file readable by root only:

```bash
cat /root/n8n-setup-credentials.txt
```

Contents:

| Variable | Meaning |
|----------|---------|
| `DOMAIN` | Configured subdomain |
| `DB_NAME` / `DB_USER` | Name of the PostgreSQL database and its user |
| `DB_PASS` | Password of the database user |
| `DB_ADMIN_PASS` | Password of the PostgreSQL superuser `postgres` |
| `N8N_ENCRYPTION_KEY` | Key used to decrypt n8n credentials |
| `N8N_PORT` / `CREWAI_PORT` | Ports of the two services |
| `TIMEZONE` | System timezone, passed on to n8n |

> **⚠️ Back this up.** `N8N_ENCRYPTION_KEY` in particular: if this key is lost, **all** credentials stored in n8n (API keys, OAuth tokens, database connections) become **permanently undecryptable**. There is no recovery — only a new, empty n8n.

---

## Pinned versions

All dependencies are deliberately **pinned** at the top of the script instead of being installed with `@latest`. The reason: n8n ships new minor versions almost weekly, and an unpinned `@latest` can break the setup between one day and the next.

| Component | Version | Note |
|-----------|---------|------|
| Node.js | `24.21.0` | Active LTS. n8n requires ≥ 20.19 |
| n8n | `2.41.6` | Stable channel. **Not** 3.x — it contains breaking changes |
| crewai | `1.15.23` | |
| fastapi | `0.142.2` | |
| uvicorn | `0.53.0` | |

### Updating versions

The pins live in the block at the top of `setup.sh`:

```bash
NODE_VERSION="24.21.0"
N8N_VERSION="2.41.6"
CREWAI_VERSION="1.15.23"
FASTAPI_VERSION="0.142.2"
UVICORN_VERSION="0.53.0"
```

After changing a version, run the script again. It is idempotent: existing services are replaced, database and credentials are preserved.

> **Note on n8n 3.0:** the n8n changelog announces 3.0 for October 2026. Upgrading to the 3.x line is **not a simple version bump** — read the [breaking changes documentation](https://docs.n8n.io/changelog/v30-breaking-changes) before updating.

---

## Important environment variables

These variables live in `/root/n8n/ecosystem.config.cjs` and are passed through by PM2 to n8n:

| Variable | Value | Purpose |
|----------|-------|---------|
| `N8N_ENCRYPTION_KEY` | generated | **Required.** Decrypts stored credentials |
| `N8N_LISTEN_ADDRESS` | `127.0.0.1` | Binds n8n locally only — no open port |
| `N8N_PROXY_HOPS` | `1` | Correct client IP detection behind the reverse proxy |
| `N8N_EDITOR_BASE_URL` | `https://$DOMAIN/` | Editor URL behind the proxy |
| `N8N_SECURE_COOKIE` | `true` | Cookies over HTTPS only |
| `N8N_WEBHOOK_URL` | `https://$DOMAIN/` | Base URL for test and production webhooks |
| `N8N_UNVERIFIED_PACKAGES_ENABLED` | `false` | Blocks installation of unverified community packages |
| `N8N_RUNNERS_TASK_TIMEOUT` | `300` | Task timeout in seconds |
| `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES` | `268435456` | Max decompressed size: 256 MiB |
| `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES` | `1000` | Max zip entries when unpacking |
| `GENERIC_TIMEZONE` | system timezone | Timezone in n8n |
| `DB_POSTGRESDB_*` | generated | Database connection |

### Adjusting the configuration

```bash
sudo nano /root/n8n/ecosystem.config.cjs
sudo pm2 restart n8n --update-env
```

### Warnings during n8n startup

On first startup n8n reports a series of deprecation warnings. The most important ones and how they are handled:

| Message | Meaning | Status |
|---------|---------|--------|
| `WEBHOOK_URL -> Use N8N_WEBHOOK_URL instead` | Old variable, being removed | ✅ **Fixed** — the script sets `N8N_WEBHOOK_URL` |
| `N8N_UNVERIFIED_PACKAGES_ENABLED ... will change to false` | Default is changing | ✅ Fixed — set to `false` explicitly |
| `N8N_RUNNERS_TASK_TIMEOUT ... will be reduced from 300 to 60` | Default is changing | ✅ Fixed — pinned to `300` |
| `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES ... 2 GiB to 256 MiB` | Default is shrinking | ✅ Fixed — set to 256 MiB |
| `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES ... 5000 to 1000` | Default is shrinking | ✅ Fixed — set to `1000` |
| `Failed to start Python task runner in internal mode` | Known n8n bug with npm installs ([n8n-io/n8n#31149](https://github.com/n8n-io/n8n/issues/31149)) | ⚠️ Known, not fixed |
| `Running n8n outside a container is deprecated` | Future versions will require Docker | ⚠️ Deliberate decision, see below |

**About the Python runner:** this message concerns only n8n's own **Python code node**. It appears because an npm installation of n8n does not ship its own venv — the official Docker image includes one. Everything else works normally. The separate **CrewAI service** of this setup is **not** affected; it has its own venv under `/opt/agent_service/venv`.

**About the container warning:** n8n has deprecated running outside of Docker and announces that future versions will require the official Docker image. This setup deliberately uses **PM2 instead of Docker**. n8n 2.41.6 currently runs fine that way. Should a future n8n version refuse the non-container installation, moving to Docker Compose is the next step — and the pinned `N8N_VERSION` in the script makes such an update plannable.

---

## Day-to-day commands

### n8n

```bash
pm2 status                              # status of all PM2 processes
pm2 logs n8n --lines 50                # last 50 log lines
pm2 logs n8n --err                     # errors only
pm2 restart n8n                        # restart
pm2 stop n8n                           # stop
pm2 save                               # save the current process list
```

### CrewAI service

```bash
sudo systemctl status crewai
sudo systemctl restart crewai
sudo journalctl -u crewai -f           # live logs
sudo systemctl cat crewai              # unit including hardening options
sudo systemctl show crewai --property=User   # must print crewai, not root
id crewai                              # check the service user's rights
ls -la /opt/agent_service/.env         # must be root:crewai 640
curl -sX POST http://127.0.0.1:8000/run-agent \
  -H 'Content-Type: application/json' \
  -d '{"topic":"Advantages of n8n"}' | python3 -m json.tool
```

### API key (quick reference)

How to set it up is described above under [Phase 4](#phase-4--enter-your-api-key-required). Here are the variables and what they mean:

| Variable | Meaning |
|----------|---------|
| `ANTHROPIC_API_KEY` | Anthropic API key. Required — without it `/run-agent` returns a 500. |
| `MODEL` | Model ID including the provider prefix, e.g. `anthropic/claude-haiku-4-5`. Without the prefix crewai falls back to LiteLLM, which would have to be installed separately. |
| `MAX_TOKENS` | Upper limit for the response. It is a required parameter for Anthropic; Haiku 4.5 allows 64000, the default here is 8192. |

The file must be `root:crewai 640`. After every change to `.env`, run `systemctl restart crewai` — the running process only reads the file at startup.

The response from `/run-agent` contains `model` and a `usage` block with `prompt_tokens`, `completion_tokens` and `total_tokens`, so the cost of a run can be read off directly.

### Database

```bash
sudo -u postgres psql -d n8n_db        # enter the database
sudo -u postgres psql -c '\l'          # list all databases
sudo systemctl status postgresql
```

### Checking autostart

```bash
systemctl is-enabled pm2-root crewai postgresql
```

All three should print `enabled`.

### Checking the state after a reboot

After a reboot everything should come back on its own:

```bash
systemctl status crewai --no-pager | head -3
systemctl show crewai --property=User      # must be crewai, not root
ss -ltn | grep 8000                        # must be listening
```

The first start after a reboot takes longer than subsequent ones — importing crewai generates the `.pyc` files for the first time. Allow 10 to 20 seconds here.

---

## Security notes

### What the script does

- ✅ Passwords and the `N8N_ENCRYPTION_KEY` are printed at the end **and** stored permanently in a `chmod 600` file (`umask 077`) readable by root only
- ✅ n8n listens on `127.0.0.1` only — port 5678 is not publicly reachable
- ✅ SQL parameters are passed via `psql -v` and `:'var'` instead of through heredoc interpolation
- ✅ The domain input is validated against invalid characters
- ✅ All passwords are 32 alphanumeric characters and are generated deterministically
- ✅ SQL errors abort the script (`ON_ERROR_STOP=1`) instead of silently continuing with a broken database
- ✅ The Anthropic API key exists only in the `.env` under `/opt/agent_service` (outside any web root) — never in the source, and therefore never in the git history
- ✅ The CrewAI service runs as its own unprivileged system user `crewai` with `/usr/sbin/nologin`, not as root
- ✅ The systemd unit uses `ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp` and further hardening options; only `/var/lib/crewai` is writable

### What you should know

> **ℹ️ The CrewAI service runs as the system user `crewai`.**
> The FastAPI server executes code generated by LLM agents — crewai interprets model output as instructions. That is why the service does not run as root but as its own unprivileged system user without a login shell. The unit additionally sets `ProtectSystem=strict` (only `/var/lib/crewai` writable), `NoNewPrivileges`, `PrivateTmp` and `ProtectKernelTunables`.
>
> This is **blast-radius limitation, not a sandbox**. A bug in the model or a manipulated prompt can crash the service and modify data under `/var/lib/crewai` — but it cannot reach the host or the other services.
>
> n8n itself still runs via PM2 as root. That is a deliberate decision of this setup: PM2 is used for the system service in [this documentation](https://docs.n8n.io/hosting/installation/npm/) and comes with no permission model of its own. For stronger isolation, a container setup would be the next step.
>
> The `.env` holding the API key lives under `/opt/agent_service` as `root:crewai` with `640` — readable by root and the service group, by nobody else.

> **⚠️ No firewall rules are set.**
> The script does not configure a firewall. For production use you should additionally open only the ports you need (22, 80, 443) and close all others.

> **⚠️ The PostgreSQL superuser password is set.**
> The script sets the password of the `postgres` user. On an existing installation using `peer` authentication this can change local login behaviour.

> **⚠️ No backups are configured.**
> The script sets up **no** backups. Configure a backup of the `n8n_db` database before going into production.

---

## Behaviour on a re-run

The script is **idempotent** and can safely be run multiple times:

- **Passwords are reused**, not regenerated. This keeps the existing database connection valid
- **`N8N_ENCRYPTION_KEY` stays unchanged** — otherwise all stored credentials would be lost
- **The domain from the credentials file is offered as the default**
- An existing swap file, installed packages and the systemd unit are detected and skipped
- The PM2 process `n8n` is deleted before the restart and recreated

This also makes the script suitable for **updating individual components** without doing a fresh installation.

---

## Troubleshooting

### The script aborts immediately with "error on line NNN"

The script uses `set -euo pipefail` and an ERR trap that names the offending line. Check the output of `bash -x setup.sh` for a full trace.

### `pm2: command not found`

After the Node installation the path may not have been reloaded:

```bash
source /etc/profile.d/nvm.sh 2>/dev/null
export PATH="$PATH:$(npm root -g | sed 's|/node_modules$|/../bin|')"
hash -r
```

### n8n does not start

```bash
pm2 logs n8n --lines 100
pm2 status
```

Most common cause: the database connection fails. Check:

```bash
sudo -u postgres psql -c "SELECT 1 FROM pg_roles WHERE rolname='n8n_db';"
```

### `n8n is not running` despite a successful installation

The state can also be down to a wrong `N8N_ENCRYPTION_KEY` — for example if the credentials file was deleted between two runs. Check whether the file exists:

```bash
ls -l /root/n8n-setup-credentials.txt
```

If it is missing, another run generates a **new** key. That only makes sense if you want to set n8n up from scratch anyway.

### n8n is unreachable

Check whether the reverse proxy is configured in aaPanel:

```bash
curl -I http://127.0.0.1:5678       # must respond locally
```

If the port responds locally but not via the domain, the problem is the reverse proxy or the SSL certificate.

### Swap was not created

```bash
swapon --show
grep swap /etc/fstab
```

On btrfs and some XFS setups `fallocate` is not supported; the script automatically falls back to `dd`.

---

## Project structure

```
.
├── setup.sh                 # The setup script for a fresh server
├── README.md                # This file
└── .gitattributes           # LF line endings
```

`setup.sh` is meant for **fresh servers** and creates everything from scratch. Running it again on an existing installation overwrites the existing data — for n8n that means the workflows, and for PostgreSQL the database.

---

## License

This script is released under the [MIT License](https://opensource.org/licenses/MIT).

---

## Related links

- [n8n documentation](https://docs.n8n.io/)
- [n8n changelog](https://docs.n8n.io/changelog)
- [CrewAI documentation](https://docs.crewai.com/)
- [FastAPI documentation](https://fastapi.tiangolo.com/)
- [aaPanel](https://www.aapanel.com/)
- [Node.js releases](https://nodejs.org/en/about/previous-releases)
