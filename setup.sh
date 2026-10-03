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
# iproute2 liefert `ss`, mit dem unten verifiziert wird, dass der
# CrewAI-Dienst wirklich auf seinem Port lauscht. Ohne das Paket
# waere die Pruefung still — sie wuerde 60 Sekunden warten und dann
# eine falsche Fehlermeldung ausgeben.
apt-get install -y curl build-essential python3-pip python3-venv python3-dev postgresql postgresql-contrib sudo iproute2

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
      // n8n 2.x: WEBHOOK_URL ist deprecated, N8N_WEBHOOK_URL gilt fuer
      // Test- und Produktions-Webhooks.
      N8N_WEBHOOK_URL: 'https://$DOMAIN/',
      // Die folgenden Defaults werden sich in kommenden n8n-Versionen
      // aendern. Hier explizit festgeschrieben, damit ein Update das
      // Verhalten nicht unbemerkt veraendert.
      N8N_UNVERIFIED_PACKAGES_ENABLED: 'false',
      N8N_RUNNERS_TASK_TIMEOUT: '300',
      // 256 MiB statt kuenftig 2 GiB: begrenzt die Entpackgroesse auf
      // einem kleinen Server und wirkt als DoS-Bremse.
      N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES: '268435456',
      N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES: '1000',
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
# /opt statt /var/www: /var/www ist typischer Website-Root in aaPanel.
# Eine .env mit API-Key läge sonst potenziell im Webroot und wäre als
# Klartext auslieferbar. /opt ist FHS-konform für Dienste und liegt
# außerhalb jedes denkbaren nginx-Roots.
AGENT_DIR="/opt/agent_service"
AGENT_USER="crewai"
AGENT_GROUP="crewai"

# Eigener unprivilegierter Systemuser für den Agent-Service.
#
# Vorher lief der Dienst als root. Das war die schwächste Stelle des
# Setups: Der FastAPI-Server führt von LLM-Agenten erzeugten Code aus,
# und crewai interpretiert Modell-Ausgaben als Anweisungen. Jeder Fehler
# im Modell, jeder manipulierte Prompt war damit ein Fehler mit
# Root-Rechten auf dem Host.
#
# --system: kein Login, keine Altersbeschränkung, System-UID-Bereich.
# --no-create-home: das Home wird nicht gebraucht, siehe STATE_DIR.
# --shell /usr/sbin/nologin: verhindert auch versehentliche SSH-Logins.
if ! getent group "$AGENT_GROUP" >/dev/null; then
    groupadd --system "$AGENT_GROUP"
fi
if ! id -u "$AGENT_USER" >/dev/null 2>&1; then
    useradd --system --gid "$AGENT_GROUP" --no-create-home \
            --shell /usr/sbin/nologin \
            --home-dir "$AGENT_DIR" --comment "CrewAI Agent Service" \
            "$AGENT_USER"
    echo "✓ Systemuser $AGENT_USER angelegt"
else
    echo "✓ Systemuser $AGENT_USER existiert bereits"
fi

mkdir -p "$AGENT_DIR"
cd "$AGENT_DIR"

if [ ! -d "venv" ]; then
    python3 -m venv venv
fi

"$AGENT_DIR/venv/bin/pip" install --upgrade --no-cache-dir pip
# Das [anthropic]-Extra installiert das native Anthropic-SDK. Ohne es
# fällt crewai auf LiteLLM zurück, was eine zusätzliche Abhängigkeit
# und ein weiterer Fehlerpfad wäre.
"$AGENT_DIR/venv/bin/pip" install --no-cache-dir \
    "crewai[anthropic]==$CREWAI_VERSION" \
    "fastapi==$FASTAPI_VERSION" \
    "uvicorn==$UVICORN_VERSION" \
    "python-dotenv"

# crewai legt seinen SQLite-Speicher über appdirs unter
# ~/.local/share/<projektname> an und ruft dabei mkdir auf. Ohne
# beschreibbares Home scheitert der Dienst. STATE_DIR ist deshalb
# ein eigener Ordner mit crewai-Eigentum, auf den die Unit per
# ReadWritePaths freigibt — der Service kann dort schreiben, ohne
# Schreibrechte auf den Projektordner selbst zu bekommen.
STATE_DIR="/var/lib/crewai"
mkdir -p "$STATE_DIR"
chown "$AGENT_USER:$AGENT_GROUP" "$STATE_DIR"
chmod 750 "$STATE_DIR"

# Vorlage ohne Secret — geht ins Repo. Die echte .env entsteht manuell
# (siehe Abschlussausgabe), damit der API-Key nie durch dieses Skript
# läuft und damit schon gar nicht im Quelltext landen kann.
cat << 'EOF' > "$AGENT_DIR/.env.example"
# Anthropic-Zugang — von Hand ausfüllen. Rechte danach auf
# root:crewai 640 setzen: der Dienst läuft als Systemuser crewai und
# muss die Datei über die Gruppe lesen können.
ANTHROPIC_API_KEY=sk-ant-enter-key-here

# Modell. Der Provider-Präfix "anthropic/" ist bei crewai Pflicht.
MODEL=anthropic/claude-haiku-4-5

# max_tokens ist bei Anthropic ein Pflichtparameter — ohne ihn wirft
# crewai bereits beim Erstellen des LLM-Objekts. Wert ist die Obergrenze
# der Antwort; Haiku 4.5 lässt 64000 zu.
MAX_TOKENS=8192
EOF

# Der API-Key wird bewusst NICHT hier hinterlegt: main.py entsteht per
# Heredoc aus diesem Skript, und setup.sh ist ein versioniertes Repo-File.
# Ein im Code eingetragener Key landet beim nächsten Commit dauerhaft in
# der Git-Historie und lässt sich nur durch Rotieren bei Anthropic
# entfernen. load_dotenv() in main.py löst das ohne Umweg.
cat << 'EOF' > "$AGENT_DIR/main.py"
import asyncio
import os
from pathlib import Path

from dotenv import load_dotenv

# Beides MUSS vor "import crewai" passieren — nicht aus Kosmetik, sondern
# weil crewai beim Import einen Pfad berechnet und sofort anlegt:
#
#   crewai/rag/chromadb/constants.py: DEFAULT_STORAGE_PATH = db_storage_path()
#
# Der Aufruf landet über appdirs in $HOME/.local/share/<projektname> und
# ruft dort mkdir auf. Ohne gesetztes CREWAI_STORAGE_DIR und ohne HOME
# wird daraus ".local" relativ zum WorkingDirectory — also
# /opt/agent_service/.local, und das ist unter ProtectSystem=strict
# read-only. Der Prozess stirbt dann schon beim Import, lange bevor
# uvicorn auf dem Port lauscht. Deshalb steht der Import bewusst unten.
load_dotenv(Path(__file__).resolve().parent / ".env")
os.environ.setdefault("CREWAI_STORAGE_DIR", "/var/lib/crewai")

from crewai import Agent, BaseLLM, Crew, LLM, Task  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from pydantic import BaseModel  # noqa: E402

app = FastAPI()


class AgentRequest(BaseModel):
    topic: str


def _build_llm() -> BaseLLM:
    # LLM.__new__ ist eine Factory: mit dem Präfix "anthropic/" gibt sie
    # ein AnthropicCompletion zurück, nicht die LLM-Klasse selbst. Der
    # Rückgabetyp ist darum BaseLLM. Ohne Präfig fällt crewai auf LiteLLM
    # zurück, das extra installiert werden müsste.
    return LLM(
        # Provider-Präfix "anthropic/" muss erhalten bleiben — ohne ihn
        # sucht crewai einen anderen Provider und rät.
        model=os.getenv("MODEL", "anthropic/claude-haiku-4-5"),
        api_key=os.getenv("ANTHROPIC_API_KEY"),
        # Obergrenze der Antwort, nicht der Zielwert. Der Default 8192
        # liegt unterhalb dessen, was Haiku 4.5 zulässt (64000).
        max_tokens=int(os.getenv("MAX_TOKENS", "8192")),
        temperature=0.3,
    )


@app.post("/run-agent")
async def run_agent(data: AgentRequest):
    llm = _build_llm()

    researcher = Agent(
        role="Research Analyst",
        goal=f"Recherchiere Informationen zu {data.topic}",
        backstory="Du bist ein erfahrener Analyst.",
        # LLM am Agent statt am Crew: damit kann crewai nicht auf einen
        # anderen Provider zurückfallen, wenn die .env fehlt.
        llm=llm,
        verbose=False,
    )

    task = Task(
        description=f"Erstelle eine Zusammenfassung zu: {data.topic}",
        expected_output="Ein prägnanter Text im Markdown-Format.",
        agent=researcher,
    )

    crew = Crew(agents=[researcher], tasks=[task])

    # kickoff() ist blockierend und dauert je nach Modell mehrere
    # Sekunden. Ohne Thread läuft die Anfrage synchron im Event-Loop
    # und der FastAPI-Server ist währenddessen nicht responsiv.
    result = await asyncio.to_thread(crew.kickoff)

    # crew.usage_metrics ist selbst die UsageMetrics und vor kickoff None —
    # result.token_usage hat dagegen eine default_factory und ist damit
    # garantiert vorhanden. Anthropic rechnet Cache-Reads und -Writes
    # bereits in prompt_tokens hinein, die nicht noch einmal addiert
    # werden dürfen.
    tokens = result.token_usage

    return {
        "status": "success",
        "model": os.getenv("MODEL", "anthropic/claude-haiku-4-5"),
        "result": str(result),
        "usage": {
            "prompt_tokens": tokens.prompt_tokens,
            "completion_tokens": tokens.completion_tokens,
            "total_tokens": tokens.total_tokens,
        },
    }
EOF

# ---------- Rechte am Projektordner ---------------------------
# Zwei Ziele gleichzeitig, die im Widerspruch zueinander stehen:
#   1. Der Dienst (als crewai) muss .env mit dem API-Key lesen können.
#   2. Der Key darf nicht für andere lokale Benutzer lesbar sein.
#
# Lösung ist eine Gruppenbesitz-Gruppe: .env gehört root:crewai mit
# 640. root darf alles, die Gruppe crewai kann lesen — und sonst
# niemand. Der Ordner selbst bleibt root:root 755, damit der Dienst
# durch ihn traversieren kann, ohne ihn zu besitzen.
#
# Wichtig: die Rechte werden NACH dem Anlegen der .env gesetzt,
# sonst würde ein chmod 600 den Dienst aus der Gruppe aussperren.
chown -R root:root "$AGENT_DIR"
chmod 755 "$AGENT_DIR"
chown root:root "$AGENT_DIR/main.py"
chmod 644 "$AGENT_DIR/main.py"

# Die .env existiert in einem frischen Setup noch gar nicht — das
# Skript legt nur .env.example an, der Key wird danach von Hand
# eingetragen. Ohne diese Prüfung bricht chown unter `set -e` das
# komplette Setup ab.
if [[ -f "$AGENT_DIR/.env" ]]; then
    chown root:"$AGENT_GROUP" "$AGENT_DIR/.env"
    chmod 640 "$AGENT_DIR/.env"
    echo "✓ Rechte an .env gesetzt (root:crewai 640)"
else
    echo -e "${YELLOW}  Noch keine .env vorhanden — Rechte werden beim${NC}"
    echo -e "${YELLOW}  manuellen Anlegen gesetzt. Nach 'nano .env':${NC}"
    echo "    chown root:crewai $AGENT_DIR/.env && chmod 640 $AGENT_DIR/.env"
fi

echo -e "\n=== 7. Systemd Service für CrewAI erstellen & starten ==="
cat << EOF > /etc/systemd/system/crewai.service
[Unit]
Description=CrewAI FastAPI Service
After=network-online.target
Wants=network-online.target

[Service]
User=$AGENT_USER
Group=$AGENT_GROUP
WorkingDirectory=$AGENT_DIR
ExecStart=$AGENT_DIR/venv/bin/uvicorn main:app --host 127.0.0.1 --port $CREWAI_PORT
Restart=always
RestartSec=5

# Zweite Verteidigungslinie neben dem setdefault() in main.py. crewai
# rechnet Speicherpfade schon beim Import aus; die Unit ist der einzige
# Ort, der garantiert VOR dem Python-Prozess gilt. Ohne HOME fällt
# appdirs auf einen Pfad relativ zum WorkingDirectory zurück, und der
# ist unter ProtectSystem=strict nicht beschreibbar.
Environment=CREWAI_STORAGE_DIR=$STATE_DIR
Environment=HOME=$STATE_DIR

# --- Härtung ---
# Das ersetzt keine echte Sandbox, aber es begrenzt die Folgen, wenn
# ein manipulierter Prompt oder ein Bug im Modell Code ausführt.

# Keine neuen setuid-Bits: verhindert Eskalation über SUID-Programme.
NoNewPrivileges=true

# Nur /var/lib/crewai beschreibbar. $AGENT_DIR wird für das Lesen der
# .env und der .py-Dateien gebraucht, nicht zum Schreiben. Ohne das
# könnte ein Fehler im Agenten die main.py überschreiben.
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$STATE_DIR

# Kein Zugriff auf proc/sys als root. Devices nur die Standard-Liste.
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now crewai

# Der Service muss nach dem Start tatsächlich laufen. systemctl
# enable --now exit 0 auch dann, wenn der Prozess direkt danach
# stirbt — etwa weil die Unit User=crewai verwendet, der User aber
# die .env nicht lesen kann, oder weil der erste Import von crewai
# fehlschlägt. Ohne diese Prüfung meldet das Skript Erfolg, während
# der Dienst tot ist.
#
# Kein fester sleep: der erste Import von crewai dauert messbar
# (pydantic, litellm, .pyc-Erzeugung beim Erstlauf). Stattdessen
# polling mit Abbruch, sobald der Dienst stirbt.
CREWAI_READY=0
for _ in $(seq 1 30); do
    if ss -ltn 2>/dev/null | grep -q ":$CREWAI_PORT[[:space:]]"; then
        CREWAI_READY=1
        break
    fi
    if ! systemctl is-active --quiet crewai; then
        break
    fi
    sleep 2
done

# Fehlt ss trotzdem (etwa weil iproute2 nicht installiert werden
# konnte), waere die Pruefung oben bedeutungslos und wuerde nach
# 60 Sekunden faelschlich "lauscht nicht" melden. In dem Fall wird
# nur gewarnt, nicht abgebrochen — der Dienst koennte laufen.
HAVE_SS=0
if command -v ss >/dev/null 2>&1; then
    HAVE_SS=1
else
    echo -e "${YELLOW}! ss nicht verfügbar — Port-Prüfung nicht möglich.${NC}"
    echo -e "${YELLOW}  Installiere iproute2 und prüfe dann:${NC}"
    echo "    apt-get install -y iproute2 && ss -ltn | grep :$CREWAI_PORT"
fi

if [[ $HAVE_SS -eq 1 ]]; then
    if [[ $CREWAI_READY -ne 1 ]]; then
        echo -e "${RED}[ABBRUCH] Der CrewAI-Service lauscht nicht auf Port $CREWAI_PORT.${NC}"
        echo "Häufigste Ursachen:"
        echo "  - Der Systemuser $AGENT_USER kann eine Datei nicht lesen."
        echo "    Prüfe: ls -la $AGENT_DIR/main.py   (sollte root:root 644 sein)"
        echo "  - Der Import von crewai scheitert."
        echo "Logs zeigen den echten Fehler:"
        echo "  systemctl status crewai"
        echo "  journalctl -u crewai --lines 50 --no-pager"
        echo
        echo "n8n und PostgreSQL laufen bereits. Nach dem Beheben:"
        echo "  systemctl restart crewai"
        exit 1
    fi
    echo "✓ CrewAI-Service läuft und lauscht auf 127.0.0.1:$CREWAI_PORT"
else
    # Ohne ss laesst sich die Bindung nicht pruefen. Der Dienst kann
    # trotzdem laufen — deshalb nur der Zustand, kein Abbruch.
    SERVICE_STATE="$(systemctl is-active crewai 2>/dev/null || true)"
    if [[ $SERVICE_STATE == "active" ]]; then
        echo -e "${YELLOW}! CrewAI-Service ist aktiv, Port konnte nicht geprüft werden.${NC}"
        echo "    Bitte manuell verifizieren: ss -ltn | grep :$CREWAI_PORT"
    else
        echo -e "${RED}[ABBRUCH] CrewAI-Service ist '$SERVICE_STATE'.${NC}"
        echo "  systemctl status crewai"
        echo "  journalctl -u crewai --lines 50 --no-pager"
        exit 1
    fi
fi

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
echo -e " - CrewAI-Serviceuser: ${YELLOW}$AGENT_USER${NC} (unprivilegiert, kein Login)"
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
echo "----------------------------------------------------------"
echo -e " ${YELLOW}ERFORDERLICH FÜR DEN CREWAI-SERVICE:${NC}"
echo -e " ${YELLOW}Ohne eingetragenen API-Key liefert /run-agent einen 500er.${NC}"
echo " Erstelle die .env aus der Vorlage und gib sie dem Dienstuser:"
echo -e "   ${GREEN}cp $AGENT_DIR/.env.example $AGENT_DIR/.env${NC}"
echo -e "   ${GREEN}nano $AGENT_DIR/.env${NC}"
echo -e "   ${GREEN}chown root:$AGENT_GROUP $AGENT_DIR/.env${NC}"
echo -e "   ${GREEN}chmod 640 $AGENT_DIR/.env${NC}"
echo " Die Gruppe $AGENT_GROUP muss die Datei lesen können — deshalb 640"
echo " und nicht 600. Danach: systemctl restart crewai"
echo " Test:   curl -sX POST http://127.0.0.1:$CREWAI_PORT/run-agent \\"
echo "           -H 'Content-Type: application/json' \\"
echo "           -d '{\"topic\":\"Vorteile von n8n\"}'"
echo "=========================================================="
