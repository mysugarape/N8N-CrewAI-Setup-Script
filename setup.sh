#!/bin/bash
# Exit bei kritischen Fehlern
set -e

# Farben für bessere Lesbarkeit
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}    INTERAKTIVES N8N & CREWAI SETUP-SKRIPT (DEBIAN 12)   ${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo ""

# ----------------------------------------------------------
# SCHRITT 1: PRÜFUNG DER VORAUSSETZUNGEN (PRE-CHECK)
# ----------------------------------------------------------
echo -e "${YELLOW}--- Schritt 1: Prüfung der Voraussetzungen ---${NC}"

# Question 1: aaPanel
read -p "1. Ist aaPanel auf diesem Server bereits fertig installiert? (y/n) [n]: " CHK_AAPANEL
CHK_AAPANEL=${CHK_AAPANEL:-n}

if [[ ! "$CHK_AAPANEL" =~ ^[Yy]$ ]]; then
    echo -e "\n${RED}[ABBRUCH] Bitte installiere zuerst aaPanel auf deinem Server.${NC}"
    echo -e "Befehl zur aaPanel Installation:"
    echo "URL=https://www.aapanel.com/script/install_6.0_en.sh && if [ -f /usr/bin/curl ]; then curl -sSO \$URL; else wget -O install_6.0_en.sh \$URL; fi && bash install_6.0_en.sh aapanel"
    echo -e "\nStarte dieses Skript neu, sobald aaPanel läuft."
    exit 1
fi

echo -e "\n${GREEN}✓ aaPanel vorhanden! Fahre mit der Konfiguration fort...${NC}\n"

# ----------------------------------------------------------
# SCHRITT 2: INTERAKTIVE ABFRAGE (NUR DOMAIN)
# ----------------------------------------------------------
echo -e "${YELLOW}--- Schritt 2: Domain-Konfiguration ---${NC}"

read -p "Subdomain für n8n [Standard: n8n.formhabr.com]: " INPUT_DOMAIN
DOMAIN=${INPUT_DOMAIN:-n8n.formhabr.com}

DB_NAME="n8n_db"
DB_USER="n8n_db"
N8N_PORT=5678
CREWAI_PORT=8000

# Sichere Zufallspasswörter (24 Zeichen) generieren
DB_ADMIN_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9')
DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9')

echo ""
echo "----------------------------------------------------------"
echo " Folgende Konfiguration wird angewendet:"
echo " - Domain:            https://$DOMAIN"
echo " - Postgres Admin PW: [Automatisch generiert]"
echo " - Datenbank:         $DB_NAME (wird automatisch angelegt)"
echo " - DB-User:           $DB_USER (wird automatisch angelegt)"
echo " - DB-Passwort:       [Automatisch generiert]"
echo "----------------------------------------------------------"
read -p "Möchtest du die Installation jetzt starten? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Installation abgebrochen."
    exit 0
fi

# ----------------------------------------------------------
# SCHRITT 3: SWAP, POSTGRESQL & SYSTEM-PAKETE
# ----------------------------------------------------------
echo -e "\n=== 1. Swap-Speicher (4 GB) wird eingerichtet ==="
if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "Swap erfolgreich eingerichtet."
else
    echo "Swap existiert bereits. Überspringe..."
fi

echo -e "\n=== 2. System-Pakete, PostgreSQL, Node.js LTS & Python3 installieren ==="
apt-get update -y
apt-get install -y curl build-essential python3-pip python3-venv python3-dev postgresql postgresql-contrib sudo

# PostgreSQL Service starten & aktivieren
systemctl enable postgresql
systemctl start postgresql

# Node.js Basis & Version-Manager 'n' installieren
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Fixieren auf stabile Node 20 LTS & npm v10 (kompatibel mit Node 20)
npm install -g npm@10 node-gyp@latest n
n 20.18.0
hash -r

# ----------------------------------------------------------
# SCHRITT 4: AUTOMATISCHE POSTGRESQL ERSTELLUNG & ADMIN PASSWORT
# ----------------------------------------------------------
echo -e "\n=== 3. PostgreSQL Admin-Passwort setzen & n8n DB/User anlegen ==="

sudo -u postgres psql <<EOF
-- PostgreSQL Superuser (postgres) Admin-Passwort setzen
ALTER USER postgres WITH PASSWORD '$DB_ADMIN_PASS';

-- User anlegen, falls er nicht existiert, sonst Passwort aktualisieren
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$DB_USER') THEN
      CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';
   ELSE
      ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';
   END IF;
END
\$\$;

-- Datenbank anlegen, falls sie nicht existiert
SELECT 'CREATE DATABASE $DB_NAME OWNER $DB_USER'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec

-- Rechte vergeben
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF

echo "PostgreSQL Admin-Passwort gesetzt sowie '$DB_NAME' erfolgreich konfiguriert."

# ----------------------------------------------------------
# SCHRITT 5: N8N INSTALLATION & SERVICE
# ----------------------------------------------------------
echo -e "\n=== 4. PM2 & n8n in der NEUESTEN Version (@latest) installieren ==="
npm cache clean --force
npm install -g pm2@latest n8n@latest

echo -e "\n=== 5. n8n PM2 Service konfigurieren & starten ==="
pm2 delete n8n 2>/dev/null || true

DB_TYPE=postgresdb \
DB_POSTGRESDB_HOST=127.0.0.1 \
DB_POSTGRESDB_PORT=5432 \
DB_POSTGRESDB_DATABASE="$DB_NAME" \
DB_POSTGRESDB_USER="$DB_USER" \
DB_POSTGRESDB_PASSWORD="$DB_PASS" \
N8N_HOST="$DOMAIN" \
N8N_PORT=$N8N_PORT \
N8N_PROTOCOL=https \
WEBHOOK_URL="https://$DOMAIN/" \
pm2 start n8n --name "n8n"

pm2 save
env PATH=$PATH:/usr/bin:/usr/local/bin /usr/local/lib/node_modules/pm2/bin/pm2 startup systemd -u root --hp /root 2>/dev/null || true

# ----------------------------------------------------------
# SCHRITT 6: CREWAI & FASTAPI SERVICE
# ----------------------------------------------------------
echo -e "\n=== 6. CrewAI & FastAPI in der NEUESTEN Version installieren ==="
AGENT_DIR="/var/www/agent_service"
mkdir -p "$AGENT_DIR"
cd "$AGENT_DIR"

if [ ! -d "venv" ]; then
    python3 -m venv venv
fi

"$AGENT_DIR/venv/bin/pip" install --upgrade --no-cache-dir pip
"$AGENT_DIR/venv/bin/pip" install --upgrade --no-cache-dir crewai fastapi uvicorn

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
cat << EOF > /etc/systemd/system/crewai.service
[Unit]
Description=CrewAI FastAPI Service
After=network.target

[Service]
User=root
WorkingDirectory=$AGENT_DIR
ExecStart=$AGENT_DIR/venv/bin/uvicorn main:app --host 127.0.0.1 --port $CREWAI_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable crewai
systemctl restart crewai

# ----------------------------------------------------------
# SCHRITT 7: ZUSAMMENFASSUNG & ZUGANGSDATEN
# ----------------------------------------------------------
echo -e "\n${GREEN}==========================================================${NC}"
echo -e "${GREEN} SETUP ERFOLGREICH ABGESCHLISTEN!                         ${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo -e "${YELLOW}GESPEICHERTE ZUGANGSDATEN & KONFIGURATION:${NC}"
echo " - n8n Domain:         https://$DOMAIN"
echo -e " - PG Admin (postgres):${GREEN}$DB_ADMIN_PASS${NC}"
echo " - Datenbank Name:     $DB_NAME"
echo " - Datenbank User:     $DB_USER"
echo -e " - DB-User Passwort:   ${GREEN}$DB_PASS${NC}"
echo " - CrewAI Endpoint:    http://127.0.0.1:$CREWAI_PORT"
echo "----------------------------------------------------------"
echo " NÄCHSTE SCHRITTE IN AAPANEL:"
echo " 1. Erstelle die Website '$DOMAIN' in aaPanel."
echo " 2. Aktiviere SSL (Let's Encrypt) & Force HTTPS."
echo " 3. Richte den Reverse Proxy ein auf: http://127.0.0.1:$N8N_PORT"
echo "=========================================================="