#!/bin/bash
# ============================================================
#  Interaktives n8n & CrewAI Setup (Debian 12 / aaPanel)
# ============================================================
#
#  Gepinnte Versionen — Update-Pflege:
#  2026-10  Node 24 (Active LTS) · n8n 2.41.6 (stable)
#           crewai 1.15.23 · fastapi 0.142.2 · uvicorn 0.53.0
# ============================================================

# ---------- Gepinnte Versionen --------------------------------
NODE_VERSION="24.21.0"      # Node Active LTS; n8n verlangt >= 20.19
N8N_VERSION="2.41.6"        # Aktueller Stable-Kanal, NICHT 3.x (Breaking)
CREWAI_VERSION="1.15.23"
FASTAPI_VERSION="0.142.2"
UVICORN_VERSION="0.53.0"
# `n` ist reines Installations-Werkzeug und wird bewusst nicht
# gepinnt — es beeinflusst das Endresultat nicht.
# ------------------------------------------------------------

# ---------- Abbruch bei kritischen Fehlern --------------------
set -euo pipefail

trap 'echo -e "\n${RED:-}[ABBRUCH] Fehler in Zeile $LINENO — Setup wird beendet.${NC:-}\n" >&2' ERR

# apt soll bei tzdata & Co. nicht interaktiv hängen bleiben
export DEBIAN_FRONTEND=noninteractive

# ---------- Farben -------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}    INTERAKTIVES N8N & CREWAI SETUP-SKRIPT (DEBIAN 12)   ${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo ""

# ---------- Root-Prüfung -------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ABBRUCH] Dieses Skript benötigt Root-Rechte.${NC}"
    echo "Bitte starten mit:  sudo bash setup.sh"
    exit 1
fi

# ---------- Hilfsfunktionen ----------------------------------

# Erzeugt exakt PASS_LENGTH alphanumerische Zeichen.
# Hex-basiert, damit die Länge deterministisch ist — im Gegensatz
# zu `openssl rand -base64 18 | tr -dc 'a-zA-Z0-9'`, dessen
# Länge durch Padding und Zeilenumbrüche schwankt.
PASS_LENGTH=32
gen_pass() {
    local raw
    raw=$(openssl rand -hex 32)
    printf '%s' "${raw:0:$PASS_LENGTH}"
}

# Frage, die auch bei nicht-interaktiver Ausführung (CI, Pipe)
# nicht den Abbruch auslöst. `read` liefert unter EOF Status 1,
# was unter `set -e` sonst das Skript sofort beenden würde.
ask() {
    local prompt="$1" varname="$2" default="$3" reply=""
    read -r -p "$prompt" reply || reply=""
    printf -v "$varname" '%s' "${reply:-$default}"
}

# ---------- Basis-Konfiguration -------------------------------
SECRETS_FILE="/root/n8n-setup-credentials.txt"

# Bestehende Secrets wiederverwenden. Ohne das rotiert ein erneuter
# Lauf die DB-Credentials und erzeugt einen neuen N8N_ENCRYPTION_KEY —
# wodurch alle in n8n gespeicherten Credentials unentschlüsselbar
# würden.
REUSED_SECRETS=0
if [[ -f $SECRETS_FILE ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
    REUSED_SECRETS=1
    echo -e "${YELLOW}Bestehende Credentials gefunden — werden wiederverwendet.${NC}"
fi

# ----------------------------------------------------------
# SCHRITT 1: PRÜFUNG DER VORAUSSETZUNGEN (PRE-CHECK)
# ----------------------------------------------------------
echo -e "${YELLOW}--- Schritt 1: Prüfung der Voraussetzungen ---${NC}"

for tool in openssl curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "${RED}[ABBRUCH] Benötigtes Werkzeug '$tool' fehlt.${NC}"
        exit 1
    fi
done
echo "✓ Benötigte Werkzeuge gefunden."

ask "1. Ist aaPanel auf diesem Server bereits fertig installiert? (y/n) [n]: " CHK_AAPANEL "n"

if [[ ! $CHK_AAPANEL =~ ^[Yy]$ ]]; then
    echo -e "\n${RED}[ABBRUCH] Bitte installiere zuerst aaPanel auf deinem Server.${NC}"
    echo -e "Befehl zur aaPanel Installation:"
    echo "URL=https://www.aapanel.com/script/install_6.0_en.sh && if [ -f /usr/bin/curl ]; then curl -sSO \$URL; else wget -O install_6.0_en.sh \$URL; fi && bash install_6.0_en.sh aapanel"
    echo -e "\nStarte dieses Skript neu, sobald aaPanel läuft."
    exit 1
fi

echo -e "\n${GREEN}✓ aaPanel vorhanden!${NC}"

# Der PostgreSQL-Manager wird über den aaPanel App-Store installiert
# (nur der Manager, keine Datenbank-Version). Das Skript richtet den
# Server und die Datenbank selbst per apt/psql ein.
ask "2. Ist der PostgreSQL-Manager in aaPanel installiert? (nur der Manager) (y/n) [y]: " CHK_PG_MANAGER "y"

if [[ ! $CHK_PG_MANAGER =~ ^[Yy]$ ]]; then
    echo -e "\n${YELLOW}[HINWEIS] Der PostgreSQL-Manager lässt sich nachträglich über"
    echo "aaPanel → App-Store → PostgreSQL Manager installieren.${NC}"
fi

echo -e "\n${GREEN}Fahre mit der Konfiguration fort...${NC}\n"

# ----------------------------------------------------------
# SCHRITT 2: INTERAKTIVE ABFRAGE (NUR DOMAIN)
# ----------------------------------------------------------
echo -e "${YELLOW}--- Schritt 2: Domain-Konfiguration ---${NC}"

# Bei einem erneuten Lauf ist die gespeicherte Domain der Standard —
# sonst würde ein Re-Run unbemerkt auf die Default-Domain zurücksetzen.
DEFAULT_DOMAIN="${DOMAIN:-n8n.formhabr.com}"
ask "Subdomain für n8n [Standard: $DEFAULT_DOMAIN]: " INPUT_DOMAIN "$DEFAULT_DOMAIN"
DOMAIN=${INPUT_DOMAIN:-$DEFAULT_DOMAIN}

# Die Domain landet in der systemd-/PM2-Konfiguration und in der
# Secrets-Datei, die per `source` eingelesen wird — ungültige Zeichen
# wie Quotes oder Shell-Metazeichen werden hier abgefangen.
if [[ ! $DOMAIN =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo -e "${RED}[ABBRUCH] Ungültige Domain: '$DOMAIN'${NC}"
    echo "Erlaubt sind nur Buchstaben, Ziffern, Punkt und Bindestrich."
    exit 1
fi

DB_NAME="${DB_NAME:-n8n_db}"
DB_USER="${DB_USER:-n8n_db}"
N8N_PORT="${N8N_PORT:-5678}"
CREWAI_PORT="${CREWAI_PORT:-8000}"

# Passwörter wiederverwenden oder frisch erzeugen
if [[ $REUSED_SECRETS -eq 1 && -n ${DB_PASS:-} && -n ${DB_ADMIN_PASS:-} && -n ${N8N_ENCRYPTION_KEY:-} ]]; then
    echo "✓ Passwörter & N8N_ENCRYPTION_KEY aus $SECRETS_FILE übernommen."
else
    DB_ADMIN_PASS=$(gen_pass)
    DB_PASS=$(gen_pass)
    # Ohne diesen Key kann n8n gespeicherte Credentials nach einem
    # Neustart nicht mehr entschlüsseln.
    N8N_ENCRYPTION_KEY=$(gen_pass)
fi

# Zeitzone aus dem System übernehmen
TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")
[[ -n $TIMEZONE ]] || TIMEZONE="UTC"

echo ""
echo "----------------------------------------------------------"
echo " Folgende Konfiguration wird angewendet:"
echo " - Domain:            https://$DOMAIN"
echo " - Postgres Admin PW: [Automatisch generiert]"
echo " - Datenbank:         $DB_NAME (wird automatisch angelegt)"
echo " - DB-User:           $DB_USER (wird automatisch angelegt)"
echo " - DB-Passwort:       [Automatisch generiert]"
if [[ $REUSED_SECRETS -eq 1 ]]; then
    echo " - Credentials-Quelle: $SECRETS_FILE (wiederverwendet)"
fi
echo "----------------------------------------------------------"
ask "Möchtest du die Installation jetzt starten? (y/n) [y]: " CONFIRM "y"

if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo "Installation abgebrochen."
    exit 0
fi

# ----------------------------------------------------------
# SCHRITT 3: SWAP, POSTGRESQL & SYSTEM-PAKETE
# ----------------------------------------------------------
echo -e "\n=== 1. Swap-Speicher (4 GB) wird eingerichtet ==="
if [ ! -f /swapfile ]; then
    # fallocate scheitert auf btrfs und einigen XFS-Setups.
    if ! fallocate -l 4G /swapfile 2>/dev/null; then
        echo "fallocate nicht unterstützt — weiche auf dd aus."
        dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
    fi
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    # Schutz gegen doppelten Eintrag bei erneutem Lauf
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo "Swap erfolgreich eingerichtet."
else
    echo "Swap existiert bereits. Überspringe..."
fi

echo -e "\n=== 2. System-Pakete, PostgreSQL, Node.js LTS & Python3 installieren ==="
apt-get update -y
apt-get install -y curl build-essential python3-pip python3-venv python3-dev postgresql postgresql-contrib sudo

# PostgreSQL Service starten & aktivieren
systemctl enable --now postgresql

# ---------- Node.js ----------
# Setup-Skript erst herunterladen, dann ausführen: bei einem
# Netzwerkfehler würde `curl … | bash -` sonst mit leerer Eingabe
# laufen und den Fehler verschlucken.
NODESOURCE_SETUP="/tmp/nodesource_setup.sh"
curl -fsSL "https://deb.nodesource.com/setup_24.x" -o "$NODESOURCE_SETUP"
bash "$NODESOURCE_SETUP"
rm -f "$NODESOURCE_SETUP"
apt-get install -y nodejs

# Auf die gepinnte LTS-Version fixieren
npm install -g npm@10 n
n "$NODE_VERSION"
hash -r
echo "✓ Node.js $(node --version) / npm $(npm --version)"

# ----------------------------------------------------------
# SCHRITT 4: AUTOMATISCHE POSTGRESQL ERSTELLUNG & ADMIN PASSWORT
# ----------------------------------------------------------
echo -e "\n=== 3. PostgreSQL Admin-Passwort setzen & n8n DB/User anlegen ==="

# ON_ERROR_STOP=1: ohne das ignoriert psql im Script-Modus SQL-Fehler
# und läuft mit einer kaputten Datenbank weiter.
# Passwörter werden über -v und :'var' übergeben, statt per
# Heredoc-Interpolation eingesetzt zu werden.
sudo -u postgres psql -v ON_ERROR_STOP=1 \
    -v db_admin_pass="$DB_ADMIN_PASS" \
    -v db_name="$DB_NAME" \
    -v db_user="$DB_USER" \
    -v db_pass="$DB_PASS" <<'EOF'
-- PostgreSQL Superuser (postgres) Admin-Passwort setzen
ALTER USER postgres WITH PASSWORD :'db_admin_pass';

-- User anlegen, falls er nicht existiert
SELECT format('CREATE USER %I WITH PASSWORD %L', :'db_user', :'db_pass')
WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = :'db_user')\gexec

-- Passwort im Bestandsfall aktualisieren
ALTER USER :"db_user" WITH PASSWORD :'db_pass';

-- Datenbank anlegen, falls sie nicht existiert
SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'db_user')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db_name')\gexec

-- Rechte vergeben
GRANT ALL PRIVILEGES ON DATABASE :"db_name" TO :"db_user";
EOF

echo "PostgreSQL Admin-Passwort gesetzt sowie '$DB_NAME' erfolgreich konfiguriert."

# ----------------------------------------------------------
# SCHRITT 5: N8N INSTALLATION & SERVICE
# ----------------------------------------------------------
echo -e "\n=== 4. PM2 & n8n (v$N8N_VERSION) installieren ==="
npm cache clean --force
npm install -g pm2@latest "n8n@$N8N_VERSION"

echo -e "\n=== 5. n8n PM2 Service konfigurieren & starten ==="

N8N_ENV_DIR="/root/n8n"
mkdir -p "$N8N_ENV_DIR"

# Die Umgebungsvariablen liegen in einer Ecosystem-Datei statt als
# Inline-Präfix am `pm2 start`-Aufruf. So hängen sie nicht von der
# Reihenfolge der Befehle ab und überleben pm2 save/startup sauber.
# N8N_LISTEN_ADDRESS=127.0.0.1 bindet n8n ausschchließlich lokal —
# ohne das lauscht der Port 0.0.0.0:5678 im Internet, solange der
# aaPanel-Reverse-Proxy und SSL noch nicht eingerichtet sind.
umask 077
cat <<EOF > "$N8N_ENV_DIR/ecosystem.config.cjs"
module.exports = {
  apps: [{
    name: 'n8n',
    script: '$(command -v n8n)',
    interpreter: 'node',
    env: {
      DB_TYPE: 'postgresdb',
      DB_POSTGRESDB_HOST: '127.0.0.1',
      DB_POSTGRESDB_PORT: '5432',
      DB_POSTGRESDB_DATABASE: '$DB_NAME',
      DB_POSTGRESDB_USER: '$DB_USER',
      DB_POSTGRESDB_PASSWORD: '$DB_PASS',
      N8N_ENCRYPTION_KEY: '$N8N_ENCRYPTION_KEY',
      N8N_HOST: '$DOMAIN',
      N8N_PORT: '$N8N_PORT',
      N8N_PROTOCOL: 'https',
      N8N_LISTEN_ADDRESS: '127.0.0.1',
      N8N_EDITOR_BASE_URL: 'https://$DOMAIN/',
      N8N_SECURE_COOKIE: 'true',
      N8N_PROXY_HOPS: '1',
      WEBHOOK_URL: 'https://$DOMAIN/',
      GENERIC_TIMEZONE: '$TIMEZONE'
    }
  }]
};
EOF
umask 022

pm2 delete n8n 2>/dev/null || true
pm2 start "$N8N_ENV_DIR/ecosystem.config.cjs" --only n8n

# ---------- PM2 Autostart ----------
# Der Pfad zu pm2 wird aufgelöst statt hartkodiert: nach `n <version>`
# liegt das globale npm-Verzeichnis unter /usr/local/n/versions/..., nicht
# unter /usr/local. Der frühere hartkodierte Pfad existierte nicht, und
# `2>/dev/null || true` verbarg den Fehler — n8n startete nach einem
# Reboot nicht. Beides ist jetzt entfernt: ein Fehler hier bricht ab.
PM2_BIN="$(command -v pm2)"
if [[ -z $PM2_BIN ]]; then
    echo -e "${RED}[ABBRUCH] pm2 nicht im PATH gefunden — Autostart kann nicht eingerichtet werden.${NC}"
    exit 1
fi
"$PM2_BIN" startup systemd -u root --hp /root
"$PM2_BIN" save
systemctl enable pm2-root.service

# n8n muss nach dem Start tatsächlich laufen, nicht nur in PM2 stehen.
# `pm2 pid` liefert bei einem abgestürzten Prozess zwar Exit 0, gibt aber
# eine leere PID aus — deshalb wird auf die Ausgabe geprüft, nicht auf $?.
sleep 5
N8N_PID="$(pm2 pid n8n 2>/dev/null || true)"
if [[ ! $N8N_PID =~ ^[0-9]+$ ]]; then
    echo -e "${RED}[ABBRUCH] n8n läuft nicht. Diagnose mit: pm2 logs n8n --lines 50${NC}"
    exit 1
fi
echo "✓ n8n läuft (PID $N8N_PID)"

# ----------------------------------------------------------
# SCHRITT 6: CREWAI & FASTAPI SERVICE
# ----------------------------------------------------------
echo -e "\n=== 6. CrewAI & FastAPI installieren ==="
AGENT_DIR="/var/www/agent_service"
mkdir -p "$AGENT_DIR"
cd "$AGENT_DIR"

if [ ! -d "venv" ]; then
    python3 -m venv venv
fi

"$AGENT_DIR/venv/bin/pip" install --upgrade --no-cache-dir pip
"$AGENT_DIR/venv/bin/pip" install --no-cache-dir \
    "crewai==$CREWAI_VERSION" \
    "fastapi==$FASTAPI_VERSION" \
    "uvicorn==$UVICORN_VERSION"

cat << 'EOF' > "$AGENT_DIR/main.py"
from fastapi import FastAPI
from pydantic import BaseModel
from crewai import Agent, Task, Crew

app = FastAPI()

class AgentRequest(BaseModel):
    topic: str

@app.post("/run-agent")
async def run_agent(data: AgentRequest):
    researcher = Agent(
        role='Research Analyst',
        goal=f'Recherchiere Informationen zu {data.topic}',
        backstory='Du bist ein erfahrener Analyst.',
        verbose=False
    )

    task = Task(
        description=f'Erstelle eine Zusammenfassung zu: {data.topic}',
        expected_output='Ein prägnanter Text im Markdown-Format.',
        agent=researcher
    )

    crew = Crew(agents=[researcher], tasks=[task])
    result = crew.kickoff()

    return {"status": "success", "result": str(result)}
EOF

echo -e "\n=== 7. Systemd Service für CrewAI erstellen & starten ==="
# ACHTUNG: User=root ist die schwächste Stelle dieses Setups.
# Der FastAPI-Server führt generierten Agent-Code aus — jeder Fehler
# in crewai oder in einem Prompt ist damit ein Root-Fehler. Besser
# wäre ein dedizierter unprivilegierter Systemuser.
cat << EOF > /etc/systemd/system/crewai.service
[Unit]
Description=CrewAI FastAPI Service
After=network-online.target
Wants=network-online.target

[Service]
User=root
WorkingDirectory=$AGENT_DIR
ExecStart=$AGENT_DIR/venv/bin/uvicorn main:app --host 127.0.0.1 --port $CREWAI_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now crewai

# ----------------------------------------------------------
# SCHRITT 7: SECRETS SPEICHERN & ZUSAMMENFASSUNG
# ----------------------------------------------------------
# Zugangsdaten werden in einer root-only-Datei (chmod 600) gesichert
# und am Ende noch einmal ausgegeben. Die Datei ist der dauerhafte
# Ablageort: die Terminal-Ausgabe verschwindet mit dem Scrollback.
umask 077
cat <<EOF > "$SECRETS_FILE"
# n8n & CrewAI Zugangsdaten — erzeugt von setup.sh
# Nur für root lesbar. Enthält im Klartext Passwörter.
# Bei Verlust von N8N_ENCRYPTION_KEY sind alle in n8n gespeicherten
# Credentials unwiederbringlich verloren.

DOMAIN='$DOMAIN'
DB_NAME='$DB_NAME'
DB_USER='$DB_USER'
DB_PASS='$DB_PASS'
DB_ADMIN_PASS='$DB_ADMIN_PASS'
N8N_ENCRYPTION_KEY='$N8N_ENCRYPTION_KEY'
N8N_PORT='$N8N_PORT'
CREWAI_PORT='$CREWAI_PORT'
TIMEZONE='$TIMEZONE'
EOF
umask 022

echo -e "\n${GREEN}==========================================================${NC}"
echo -e "${GREEN} SETUP ERFOLGREICH ABGESCHLISTEN!                         ${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo -e "${YELLOW}INSTALLIERTE VERSIONEN:${NC}"
echo " - Node.js:            $(node --version)"
echo " - npm:                $(npm --version)"
echo " - n8n:                $( { n8n --version 2>/dev/null || echo "installiert, siehe: npm ls -g n8n"; } | head -1 )"
echo " - crewai / fastapi:   $CREWAI_VERSION / $FASTAPI_VERSION"
echo " - uvicorn:            $UVICORN_VERSION"
echo "----------------------------------------------------------"
echo -e "${YELLOW}ZUGANGSDATEN:${NC}"
echo " - n8n Domain:         https://$DOMAIN"
echo -e " - CrewAI Endpoint:    http://127.0.0.1:$CREWAI_PORT"
if [[ $REUSED_SECRETS -eq 1 ]]; then
    echo " - (unverändert aus vorherigem Setup übernommen)"
fi
echo "----------------------------------------------------------"
echo -e "${YELLOW}GENERIERTE PASSWÖRTER — bitte sicher verwahren:${NC}"
echo -e " - Postgres Admin ('postgres'):   ${YELLOW}$DB_ADMIN_PASS${NC}"
echo -e " - Datenbank-User ($DB_USER):   ${YELLOW}$DB_PASS${NC}"
echo -e " - N8N_ENCRYPTION_KEY:            ${YELLOW}$N8N_ENCRYPTION_KEY${NC}"
echo " - Datenbank-Name:      $DB_NAME"
echo "----------------------------------------------------------"
echo -e "${RED}ACHTUNG: Diese Passwörter stehen jetzt im Terminal-Scrollback"
echo "und in Logs, falls die Ausgabe umgeleitet wurde. Bewahre die"
echo "Credentials-Datei sicher auf und lösche sie nicht:${NC}"
echo -e "   ${GREEN}$SECRETS_FILE${NC}"
echo -e "   ${GREEN}cat $SECRETS_FILE${NC}"
echo "----------------------------------------------------------"
echo " NÄCHSTE SCHRITTE IN AAPANEL:"
echo " 1. Erstelle die Website '$DOMAIN' in aaPanel."
echo " 2. Aktiviere SSL (Let's Encrypt) & Force HTTPS."
echo " 3. Richte den Reverse Proxy ein auf: http://127.0.0.1:$N8N_PORT"
echo "    (n8n lauscht bewusst nur auf 127.0.0.1 — ohne Proxy kein Zugriff)"
echo "=========================================================="
