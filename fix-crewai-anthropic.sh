#!/bin/bash
# ============================================================
#  Nachtrag: CrewAI-Service auf Anthropic umstellen
#
#  Für Server, die mit einer ÄLTEREN Fassung von setup.sh
#  eingerichtet wurden. Diese Fassung legt den Agent-Service
#  noch unter /var/www/agent_service an und kennt weder .env
#  noch Anthropic.
#
#  Das Skript ist eigenständig: es installiert nichts Neues für
#  n8n und greift nicht in die Credentials-Datei ein. Es erzeugt
#  exakt den Zustand, den die aktuelle setup.sh auf einem frischen
#  Server herstellen würde — nur auf einer bestehenden Installation.
#
#  Aufruf:  sudo bash fix-crewai-anthropic.sh
# ============================================================

set -euo pipefail
trap 'echo -e "\n${RED:-}[ABBRUCH] Fehler in Zeile $LINENO — Abbruch.${NC:-}\n" >&2' ERR

# Gepinnt, identisch zu setup.sh — siehe dort die Update-Pflege.
CREWAI_VERSION="1.15.23"
FASTAPI_VERSION="0.142.2"
UVICORN_VERSION="0.53.0"

OLD_DIR="/var/www/agent_service"
AGENT_DIR="/opt/agent_service"
AGENT_USER="crewai"
AGENT_GROUP="crewai"
STATE_DIR="/var/lib/crewai"
UNIT="/etc/systemd/system/crewai.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   CREWAI-SERVICE AUF ANTHROPIC UMSTELLEN                ${NC}"
echo -e "${GREEN}==========================================================${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ABBRUCH] Root-Rechte erforderlich.${NC}"
    echo "Bitte starten mit:  sudo bash fix-crewai-anthropic.sh"
    exit 1
fi

# ---------- Zustand feststellen --------------------------------
# Nichts davon ist eine Annahme: der Port wird aus der laufenden
# Unit gelesen, nicht aus einem Default. Wer beim Setup einen
# anderen Port gewählt hat, soll ihn nach dem Fix nicht verlieren.
CREWAI_PORT="8000"
if [[ -f $UNIT ]]; then
    # [0-9][0-9]* statt \+ : \+ ist eine GNU-sed-Erweiterung und liefert
    # auf Busybox/macOS nichts. Die Variante funktioniert ueberall.
    EXISTING_PORT="$(sed -n 's/.*--port[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$UNIT" | head -1)"
    if [[ -n $EXISTING_PORT ]]; then
        CREWAI_PORT="$EXISTING_PORT"
        echo "✓ Bestehender CrewAI-Port übernommen: $CREWAI_PORT"
    else
        echo -e "${YELLOW}! Port konnte nicht aus der Unit gelesen werden —${NC}"
        echo -e "${YELLOW}  Default 8000 wird verwendet. Prüfe danach:${NC}"
        echo "    grep -- --port $UNIT"
    fi
else
    echo -e "${YELLOW}! Keine bestehende Unit gefunden — Default-Port 8000.${NC}"
fi

# ---------- Alten Zustand sichern --------------------------------
# Vor dem Umbau. Ohne Backup wäre ein Fehler hier nicht rückgängig
# zu machen, weil die alte main.py überschrieben wird.
BACKUP_DIR="$AGENT_DIR.backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [[ -d $OLD_DIR ]]; then
    echo "✓ Sichere $OLD_DIR/main.py und .env nach $BACKUP_DIR"
    for f in main.py .env; do
        [[ -f "$OLD_DIR/$f" ]] && cp -p "$OLD_DIR/$f" "$BACKUP_DIR/$f"
    done
    # Das alte venv wird NICHT mitverschoben: pyvenv.cfg, Shebangs
    # in bin/ und .pth-Dateien enthalten absolute Pfade auf
    # /var/www/agent_service. Ein mv ergäbe ein formal vorhandenes,
    # aber unbrauchbares venv mit der Fehlermeldung "bad interpreter".
    # Der Aufbau unten ist schneller als jede Reparatur.
    echo "  (venv wird nicht kopiert — wird neu aufgebaut)"
else
    echo -e "${YELLOW}! $OLD_DIR existiert nicht.${NC}"
    echo -e "${YELLOW}  Es wird von Grund auf eingerichtet. Falls der Service${NC}"
    echo -e "${YELLOW}  woanders liegt, brich ab und prüfe vorher:${NC}"
    echo "    systemctl cat crewai"
    echo -e "${YELLOW}  Fortfahren? (y/n) [n]: ${NC}"
    read -r reply || reply=""
    if [[ ! $reply =~ ^[Yy]$ ]]; then
        echo "Abgebrochen."
        exit 1
    fi
fi

# Eine .env aus der alten Installation wird übernommen, damit ein
# bereits eingetragener Key nicht verloren geht.
CARRY_ENV=0
if [[ -f "$OLD_DIR/.env" ]]; then
    CARRY_ENV=1
fi

# ---------- Service anhalten ------------------------------------
# Muss vor dem Umbau passieren: uvicorn hält die alte main.py offen
# und würde sie beim Neustart aus einem gelöschten inode lesen.
if systemctl is-active --quiet crewai; then
    echo "✓ Stoppe laufenden crewai-Service"
    systemctl stop crewai
else
    echo "  crewai-Service läuft derzeit nicht"
fi

# ---------- Neu aufbauen ---------------------------------------
echo -e "\n=== 1. Verzeichnis, Systemuser und venv anlegen ==="

# Eigener unprivilegierter Systemuser statt root. Der FastAPI-Server
# führt von LLM-Agenten erzeugten Code aus — crewai interpretiert
# Modell-Ausgaben als Anweisungen. Als root war jeder Modell-Fehler
# ein Root-Fehler auf dem Host.
if ! getent group "$AGENT_GROUP" >/dev/null; then
    groupadd --system "$AGENT_GROUP"
    echo "✓ Gruppe $AGENT_GROUP angelegt"
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

python3 -m venv venv
"$AGENT_DIR/venv/bin/pip" install --upgrade --no-cache-dir pip

echo -e "\n=== 2. Abhängigkeiten installieren ==="
# [anthropic] statt plain crewai: damit kommt das native
# Anthropic-SDK. Ohne es fällt crewai auf LiteLLM zurück.
"$AGENT_DIR/venv/bin/pip" install --no-cache-dir \
    "crewai[anthropic]==$CREWAI_VERSION" \
    "fastapi==$FASTAPI_VERSION" \
    "uvicorn==$UVICORN_VERSION" \
    "python-dotenv"

# ---------- .env.example ----------------------------------------
echo -e "\n=== 3. .env.example schreiben ==="
cat << 'EOF' > "$AGENT_DIR/.env.example"
# Anthropic-Zugang — von Hand ausfüllen. Rechte danach auf
# root:crewai 640 setzen: der Dienst läuft als Systemuser crewai und
# muss die Datei über die Gruppe lesen können.
ANTHROPIC_API_KEY=sk-ant-hier-eintragen

# Modell. Der Provider-Präfix "anthropic/" ist bei crewai Pflicht.
MODEL=anthropic/claude-haiku-4-5

# max_tokens ist bei Anthropic ein Pflichtparameter — ohne ihn wirft
# crewai bereits beim Erstellen des LLM-Objekts. Wert ist die Obergrenze
# der Antwort; Haiku 4.5 lässt 64000 zu.
MAX_TOKENS=8192
EOF

# Alte .env übernehmen, damit ein bereits eingetragener Key nicht
# verloren geht. Fehlt ANTHROPIC_API_KEY noch, ist das kein Fehler —
# dann muss der Key ohnehin neu eingetragen werden.
if [[ $CARRY_ENV -eq 1 ]]; then
    cp -p "$OLD_DIR/.env" "$AGENT_DIR/.env"
    echo "✓ Bestehende .env übernommen"
else
    cp "$AGENT_DIR/.env.example" "$AGENT_DIR/.env"
    echo "✓ .env aus Vorlage erstellt"
fi

# ---------- Rechte ---------------------------------------------
# Zwei Ziele im Widerspruch: der Dienst (als crewai) muss den API-Key
# lesen können, und der Key darf für keine anderen lokalen Benutzer
# lesbar sein. Gruppenbesitz löst beides — root:crewai mit 640 heißt
# "root darf alles, die Gruppe crewai darf lesen, sonst niemand".
#
# 600 wäre hier falsch: der Dienst liefe als crewai und käme nicht mehr
# an die Datei.
chown -R root:root "$AGENT_DIR"
chmod 755 "$AGENT_DIR"
chown root:"$AGENT_GROUP" "$AGENT_DIR/.env"
chmod 640 "$AGENT_DIR/.env"
chown root:root "$AGENT_DIR/main.py"
chmod 644 "$AGENT_DIR/main.py"

mkdir -p "$STATE_DIR"
chown "$AGENT_USER:$AGENT_GROUP" "$STATE_DIR"
chmod 750 "$STATE_DIR"

# ---------- API-Key prüfen ------------------------------------
# Drei Zustände unterscheiden, nicht zwei: fehlender Key, leerer Wert
# und der Platzhalter aus der Vorlage fuehren alle zum 500er, sind
# aber unterschiedliche Fehler. Der Platzhalter wird bewusst NICHT
# als gesetzt gewertet.
if grep -q '^ANTHROPIC_API_KEY=sk-ant-hier-eintragen' "$AGENT_DIR/.env"; then
    echo -e "${YELLOW}  ! ANTHROPIC_API_KEY steht noch auf dem Platzhalter.${NC}"
    echo -e "${YELLOW}    Bitte von Hand eintragen:  nano $AGENT_DIR/.env${NC}"
elif ! grep -q '^ANTHROPIC_API_KEY=..*' "$AGENT_DIR/.env"; then
    echo -e "${YELLOW}  ! Kein ANTHROPIC_API_KEY gefunden — die alte .env war${NC}"
    echo -e "${YELLOW}    vermutlich für OpenAI gedacht. Key bitte eintragen:${NC}"
    echo -e "    ${GREEN}nano $AGENT_DIR/.env${NC}"
else
    echo "  ✓ ANTHROPIC_API_KEY vorhanden"
fi

# ---------- main.py ---------------------------------------------
# Identisch zum Heredoc in setup.sh. Beide Stellen manuell
# synchron zu halten ist die einzige Fehlerquelle in diesem
# Skript — siehe Commit-Nachricht.
echo -e "\n=== 4. main.py schreiben ==="
cat << 'EOF' > "$AGENT_DIR/main.py"
import asyncio
import os
from pathlib import Path

from crewai import Agent, BaseLLM, Crew, LLM, Task
from dotenv import load_dotenv
from fastapi import FastAPI
from pydantic import BaseModel

# Absoluter Pfad statt "load_dotenv()": uvicorn startet mit
# WorkingDirectory=AGENT_DIR, aber ein manueller Aufruf aus einem
# anderen Verzeichnis würde die .env sonst nicht finden.
load_dotenv(Path(__file__).resolve().parent / ".env")

# crewai legt seinen SQLite-Speicher über appdirs unter
# ~/.local/share/<projektname> an und ruft dabei mkdir auf. Der Dienst
# läuft als unprivilegierter Systemuser ohne beschreibbares Home —
# ohne dieses Verzeichnis scheitert der Start. Der Pfad ist in der
# systemd-Unit über ReadWritePaths freigegeben.
#
# setdefault, nicht hart setzen: ein Betreiber kann den Wert in der .env
# überschreiben, und der Default greift nur, wenn er fehlt.
os.environ.setdefault("CREWAI_STORAGE_DIR", "/var/lib/crewai")

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

# ---------- systemd-Unit ----------------------------------------
echo -e "\n=== 5. systemd-Unit aktualisieren ==="
# User=root ist hier durch den Systemuser crewai ersetzt. Die Härtung
# begrenzt die Folgen, wenn ein manipulierter Prompt oder ein Bug im
# Modell Code ausführt — sie ist keine echte Sandbox, aber ein
# sinnvoller Rahmen.
cat << EOF > "$UNIT"
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

# --- Härtung ---
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$STATE_DIR
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
systemctl enable crewai
systemctl restart crewai

# ---------- Prüfen, ob der Dienst wirklich läuft ---------------
# systemctl restart exit 0, auch wenn der Prozess direkt danach
# stirbt. Deshalb auf die tatsächliche Antwort warten, statt auf
# den Exit-Code zu vertrauen.
SERVICE_STATE="$(systemctl is-active crewai 2>/dev/null || true)"
if [[ $SERVICE_STATE != "active" ]]; then
    echo -e "${RED}[ABBRUCH] crewai-Service ist '$SERVICE_STATE'.${NC}"
    echo "Diagnose mit:"
    echo "  systemctl status crewai"
    echo "  journalctl -u crewai --lines 50 --no-pager"
    echo
    echo "Die alte Installation liegt weiterhin unter $OLD_DIR."
    echo "Backup der überschriebenen Dateien: $BACKUP_DIR"
    exit 1
fi

# Auf die tatsächliche Bindung warten statt auf ein festes sleep.
# Nach einem frischen venv-Aufbau braucht der erste Import von
# crewai mehrere Sekunden — es importiert pydantic, litellm und
# weitere schwere Module, und beim ersten Lauf kommen die .pyc-Dateien
# erst noch hinzu. systemctl meldet in dieser Zeit schon "active",
# weil der Prozess läuft, obwohl der Port noch nicht gebunden ist.
# Ein festes sleep 5 war darum die falsche Annahme.
PORT_OPEN=0
for _ in $(seq 1 30); do
    if ss -ltn 2>/dev/null | grep -q ":$CREWAI_PORT[[:space:]]"; then
        PORT_OPEN=1
        break
    fi
    # Ein toter Prozess wird nicht durch weiteres Warten gut.
    if ! systemctl is-active --quiet crewai; then
        break
    fi
    sleep 2
done

if [[ $PORT_OPEN -ne 1 ]]; then
    echo -e "${RED}[ABBRUCH] nichts lauscht auf Port $CREWAI_PORT.${NC}"
    echo "Der Service läuft, bindet den Port aber nicht. Meistens"
    echo "liegt es am Import von crewai oder am fehlenden API-Key."
    echo "Logs zeigen den echten Fehler:"
    echo "  journalctl -u crewai --lines 50 --no-pager"
    echo
    echo "Die alte Installation liegt weiterhin unter $OLD_DIR."
    echo "Backup der überschriebenen Dateien: $BACKUP_DIR"
    exit 1
fi

echo "✓ Service läuft und lauscht auf 127.0.0.1:$CREWAI_PORT"

# ---------- Altes Verzeichnis aufräumen -----------------------
if [[ -d $OLD_DIR ]]; then
    echo -e "\n=== 6. Altes Verzeichnis entfernen ==="
    echo "Sichere vor dem Löschen umbenannt:"
    mv "$OLD_DIR" "${OLD_DIR}.old-$(date +%Y%m%d-%H%M%S)"
    echo "  ${OLD_DIR}.old-*"
    echo "Enthält das alte venv mit ungültigen Shebangs und — falls"
    echo "dort eine .env lag — einen API-Key im Webroot. Nach dem"
    echo "Prüfen des neuen Services löschen:"
    echo -e "  ${GREEN}rm -rf ${OLD_DIR}.old-*${NC}"
fi

# ---------- Zusammenfassung ------------------------------------
echo -e "\n${GREEN}==========================================================${NC}"
echo -e "${GREEN} UMSTELLUNG ABGESCHLOSSEN                                ${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo " - Projektordner:  $AGENT_DIR"
echo " - venv:           $AGENT_DIR/venv"
echo " - .env:           $AGENT_DIR/.env (root:crewai 640)"
echo " - Serviceuser:    $AGENT_USER (unprivilegiert, kein Login)"
echo " - State-Dir:      $STATE_DIR"
echo " - Endpoint:       http://127.0.0.1:$CREWAI_PORT"
echo " - Backup:         $BACKUP_DIR"
echo "----------------------------------------------------------"
echo -e "${YELLOW}FALLS NOCH KEIN ANTHROPIC-KEY GESETZT IST:${NC}"
echo -e "   ${GREEN}nano $AGENT_DIR/.env${NC}"
echo -e "   ${GREEN}systemctl restart crewai${NC}"
echo "----------------------------------------------------------"
echo -e "${YELLOW}TEST EINES AGENTENLAUFS:${NC}"
echo "  curl -sX POST http://127.0.0.1:$CREWAI_PORT/run-agent \\"
echo "    -H 'Content-Type: application/json' \\"
# python3, nicht python: auf Debian 12 existiert nur python3. Der
# Name python gehoert zum Paket python-is-python3, das nicht Teil der
# Standardinstallation ist.
echo "    -d '{\"topic\":\"Vorteile von n8n\"}' | python3 -m json.tool"
echo "=========================================================="
