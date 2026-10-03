# n8n & CrewAI Setup-Skript (Debian 12 / aaPanel)

Ein interaktives, idempotentes Bash-Skript, das auf einem **Debian 12**-Server mit **aaPanel** eine vollständige n8n-Installation mit PostgreSQL-Datenbank sowie einen CrewAI/FastAPI-Microservice einrichtet — beides über systemd bzw. PM2 dauerhaft im Autostart.

[![Shell](https://img.shields.io/badge/shell-bash-blue.svg)](https://www.gnu.org/software/bash/)
[![Debian](https://img.shields.io/badge/debian-12-red.svg)](https://www.debian.org/)

Repository: [github.com/mysugarape/N8N-CrewAI-Setup-Script](https://github.com/mysugarape/N8N-CrewAI-Setup-Script)

---

## Inhalt

- [Was das Skript macht](#was-das-skript-macht)
- [Voraussetzungen](#voraussetzungen)
- [Installation](#installation)
  - [5. API-Key eintragen (Pflicht)](#5-api-key-eintragen-pflicht)
- [Nach der Installation: manuelle Schritte in aaPanel](#nach-der-installation-manuelle-schritte-in-aapanel)
- [Zugangsdaten](#zugangsdaten)
- [Gepinnte Versionen](#gepinnte-versionen)
- [Wichtige Umgebungsvariablen](#wichtige-umgebungsvariablen)
- [Befehle für den Alltag](#befehle-für-den-alltag)
- [Sicherheitshinweise](#sicherheitshinweise)
- [Verhalten bei erneutem Lauf](#verhalten-bei-erneutem-lauf)
- [Fehlerbehebung](#fehlerbehebung)
- [Projektstruktur](#projektstruktur)

---

## Was das Skript macht

Das Skript führt sieben Schritte in einer durchgehenden, fehlertoleranten Session aus:

| Schritt | Inhalt |
|---------|--------|
| **1. Pre-Check** | Prüft Root-Rechte, benötigte Werkzeuge (`openssl`, `curl`) und fragt ab, ob aaPanel sowie der PostgreSQL-Manager bereits laufen |
| **2. Konfiguration** | Fragt die Subdomain ab, generiert Passwörter und den `N8N_ENCRYPTION_KEY` |
| **3. System** | Richtet 4 GB Swap ein, installiert Systempakete, PostgreSQL, Node.js LTS und Python3 |
| **4. Datenbank** | Setzt das PostgreSQL-Superuser-Passwort und legt Datenbank, User und Rechte an |
| **5. n8n** | Installiert n8n, schreibt eine PM2-Ecosystem-Datei, startet den Dienst und richtet den Reboot-Autostart ein |
| **6. CrewAI** | Erstellt ein venv, installiert CrewAI/FastAPI/uvicorn, schreibt eine Beispiel-API und registriert sie als systemd-Service |
| **7. Abschluss** | Schreibt alle Zugangsdaten in eine root-only-Datei und fasst die Versionen zusammen |

### Konfigurationsdateien, die das Skript anlegt

```
/swapfile                                  4 GB Swap
/etc/systemd/system/crewai.service         systemd-Unit für den FastAPI-Service
/opt/agent_service/main.py                 Beispiel-API mit einem CrewAI-Agenten
/opt/agent_service/.env.example            Vorlage für API-Key und Modell
/opt/agent_service/venv/                    Python-virtualenv
/var/lib/crewai/                           Schreibbare Daten des Dienstes (SQLite)
/root/n8n/ecosystem.config.cjs             PM2-Konfiguration mit allen n8n-Variablen
/root/n8n-setup-credentials.txt            Zugangsdaten (nur für root lesbar)
```

Dazu ein unprivilegierter Systemuser `crewai` (UID aus dem System-Bereich, keine Login-Shell), unter dem der Agent-Service läuft. Er ist im Gegensatz zu root nicht interaktiv nutzbar:

```bash
id crewai          # uid=..., no-create-home, shell /usr/sbin/nologin
```

> **Warum `/opt` und nicht `/var/www`:** `/var/www` ist in aaPanel der typische Website-Root. Eine `.env` mit dem API-Key läge dort im Webroot und wäre als Klartext auslieferbar. `/opt` liegt außerhalb und ist FHS-konform für Dienste.

---

## Voraussetzungen

- **Betriebssystem:** Debian 12 (Bookworm) — andere Distributionen werden nicht getestet
- **aaPanel:** muss bereits installiert und laufend sein
- **PostgreSQL-Manager in aaPanel:** muss über den App-Store von aaPanel installiert sein — **nur der Manager, nicht die Datenbank selbst** (siehe Hinweis unten)
- **Root-Rechte:** das Skript legt Systemdateien an und startet Dienste
- **Netzwerkzugriff** für `apt`, NodeSource und npm
- **Fester Speicherplatz** von ca. 10 GB (Swap, PostgreSQL, Node-Module, Python-venv)

### PostgreSQL-Manager über aaPanel

Installiere vor dem Setup unter **aaPanel → App-Store → PostgreSQL Manager** den **Manager selbst**. Wähle dabei **keine** PostgreSQL-Version aus und lass keine Datenbank anlegen — das Skript erledigt beides anschließend selbst:

- den PostgreSQL-Server per `apt-get install postgresql`
- das Passwort des Superusers `postgres`
- die Datenbank `n8n_db`, den User `n8n_db` und dessen Rechte

> **Warum nur der Manager?** Wenn du im App-Store eine PostgreSQL-Version installierst, legt aaPanel eine eigene, abweichende Installation an. Das Skript würde dann `systemctl enable --now postgresql` auf einen Dienst anwenden, den aaPanel verwaltet — die Konfigurationen laufen auseinander. Installierst du nur den Manager, bleibt aaPanel die Verwaltungsoberfläche, der eigentliche Server stammt aber aus dem Skript.
>
> **Nach der Installation:** Der Manager in aaPanel kann nach dem Setup genutzt werden, um die Datenbank zu verwalten, Backups zu erstellen und Logs einzusehen. Damit der Dienst weiterhin von systemd und nicht von aaPanel gesteuert wird, ändere nichts an der PostgreSQL-Version im App-Store.

> **Hinweis:** Bei einem frischen Debian 12 mit weniger als 4 GB RAM ist die Swap-Datei Pflicht, da PostgreSQL und n8n sonst beim Start in den OOM-Killer laufen.

---

## Installation

### 1. Repository klonen

```bash
git clone https://github.com/mysugarape/N8N-CrewAI-Setup-Script.git
cd N8N-CrewAI-Setup-Script
```

> **Vorher erledigen:** Stelle sicher, dass aaPanel läuft und der **PostgreSQL-Manager** über den App-Store installiert ist (nur der Manager, keine Datenbank-Version — Details unter [Voraussetzungen](#voraussetzungen)).

### 2. Skript ausführen

```bash
sudo bash setup.sh
```
Das Skript ist **vollständig interaktiv** und führt durch vier Abfragen:

```
1. Ist aaPanel auf diesem Server bereits fertig installiert? (y/n) [n]:
2. Ist der PostgreSQL-Manager in aaPanel installiert? (nur der Manager) (y/n) [y]:
   → Domain-Abfrage:  Subdomain für n8n [Standard: n8n.formhabr.com]:
   → Bestätigung:     Möchtest du die Installation jetzt starten? (y/n) [y]:
```

> **Tipp:** Jede Eingabe kann mit **Enter** bestätigt werden, um den Standard zu übernehmen. Das Skript funktioniert auch ohne TTY — fehlende Eingaben fallen dann auf die Standardwerte zurück (nützlich für CI).

### 3. Laufzeit

Je nach Server-Leistung dauert die Installation **10 bis 25 Minuten**. Die größten Zeitfresser sind der Download der Node-Module und das Kompilieren der Python-Abhängigkeiten.

### 4. Ergebnis

Bei erfolgreichem Abschluss erscheint eine Zusammenfassung:

```
==========================================================
 SETUP ERFOLGREICH ABGESCHLISTEN!
==========================================================
INSTALLIERTE VERSIONEN:
 - Node.js:            v24.21.0
 - npm:                10.x.y
 - n8n:                2.41.6
 - crewai / fastapi:   1.15.23 / 0.142.2
 - uvicorn:            0.53.0
----------------------------------------------------------
ZUGANGSDATEN:
 - n8n Domain:         https://n8n.formhabr.com
 - CrewAI Endpoint:    http://127.0.0.1:8000
----------------------------------------------------------
GENERIERTE PASSWÖRTER — bitte sicher verwahren:
 - Postgres Admin ('postgres'):   <generiertes Passwort>
 - Datenbank-User (n8n_db):   <generiertes Passwort>
 - N8N_ENCRYPTION_KEY:            <generierter Schlüssel>
 - Datenbank-Name:      n8n_db
 - CrewAI-Serviceuser: crewai (unprivilegiert, kein Login)
----------------------------------------------------------
ERFORDERLICH FÜR DEN CREWAI-SERVICE:
Ohne eingetragenen API-Key liefert /run-agent einen 500er.
   cp /opt/agent_service/.env.example /opt/agent_service/.env
   nano /opt/agent_service/.env
   chown root:crewai /opt/agent_service/.env
   chmod 640 /opt/agent_service/.env
   systemctl restart crewai
----------------------------------------------------------
ACHTUNG: Diese Passwörter stehen jetzt im Terminal-Scrollback
und in Logs, falls die Ausgabe umgeleitet wurde. Bewahre die
Credentials-Datei sicher auf und lösche sie nicht:
   /root/n8n-setup-credentials.txt
   cat /root/n8n-setup-credentials.txt
```

*(Die npm-Version hängt von der zum Installationszeitpunkt verfügbaren npm-10-Release ab und kann variieren. Die Passwörter sind hier nur als Platzhalter dargestellt.)*

### 5. API-Key eintragen (Pflicht)

Das Setup ist danach **vollständig**, aber der Agent-Dienst kann noch keine Anfragen beantworten. Das Skript legt absichtlich nur eine Vorlage an — ein im Quelltext hinterlegter Key würde beim nächsten Commit dauerhaft in der Git-Historie landen.

```bash
cp /opt/agent_service/.env.example /opt/agent_service/.env
nano /opt/agent_service/.env                 # ANTHROPIC_API_KEY=sk-ant-...
chown root:crewai /opt/agent_service/.env    # Gruppe der Dienst muss lesen können
chmod 640 /opt/agent_service/.env            # NICHT 600 — siehe Erklärung
sudo systemctl restart crewai
```

> **Warum `640` und nicht `600`:** Der Dienst läuft als Systemuser `crewai`, nicht als root. Bei `600` mit Besitzer root käme er nicht mehr an den Key und jeder Request liefe in einen 500er. `root:crewai 640` bedeutet: root darf alles, die Gruppe `crewai` darf lesen, alle anderen Benutzer des Servers nicht.

Prüfen, ohne den Key auszugeben:

```bash
cd /opt/agent_service && ./venv/bin/python -c "
import main, os
k = os.getenv('ANTHROPIC_API_KEY') or ''
print('Key gesetzt:', bool(k))
print('Platzhalter:', k == 'sk-ant-hier-eintragen')
print('Modell:     ', main._build_llm().model)
"
```

Danach der erste echte Lauf (kostet Tokens):

```bash
curl -sX POST http://127.0.0.1:8000/run-agent \
  -H 'Content-Type: application/json' \
  -d '{"topic":"Vorteile von n8n"}' | python3 -m json.tool
```

---

## Nach der Installation: manuelle Schritte in aaPanel

Das Skript konfiguriert die Dienste, **nicht** den Reverse Proxy und **nicht** SSL. Diese Schritte musst du in aaPanel selbst durchführen:

1. **Website anlegen** — unter *Websites* eine Website für deine Subdomain erstellen.
2. **SSL aktivieren** — unter *SSL* ein Let's-Encrypt-Zertifikat ausstellen und **Force HTTPS** aktivieren.
3. **Reverse Proxy einrichten** — auf `http://127.0.0.1:5678` weiterleiten.

> **Wichtig:** n8n lauscht bewusst nur auf `127.0.0.1` (siehe `N8N_LISTEN_ADDRESS`). **Solange der Reverse Proxy nicht eingerichtet ist, ist n8n nicht erreichbar.** Das ist beabsichtigt: so liegt der Port niemals ungeschützt im Internet.

Optional kannst du im selben Panel einen zweiten Reverse Proxy auf `http://127.0.0.1:8000` für den CrewAI-Service anlegen.

### Ersten n8n-Login

Beim ersten Aufruf von n8n legst du ein Owner-Konto an. **Die Zugangsdaten dafür vergibst du selbst** — sie werden nicht vom Skript erzeugt.

---

## Zugangsdaten

Die generierten Passwörter werden **am Ende des Setups ausgegeben** und zusätzlich dauerhaft in einer Datei gesichert, die nur für root lesbar ist:

```bash
cat /root/n8n-setup-credentials.txt
```

Inhalt:

| Variable | Bedeutung |
|----------|-----------|
| `DOMAIN` | Konfigurierte Subdomain |
| `DB_NAME` / `DB_USER` | Name der PostgreSQL-Datenbank und ihres Users |
| `DB_PASS` | Passwort des Datenbank-Users |
| `DB_ADMIN_PASS` | Passwort des PostgreSQL-Superusers `postgres` |
| `N8N_ENCRYPTION_KEY` | Schlüssel zum Entschlüsseln der n8n-Credentials |
| `N8N_PORT` / `CREWAI_PORT` | Ports der beiden Dienste |
| `TIMEZONE` | Systemzeitzone, an n8n übergeben |

> **⚠️ Unbedingt sichern.** Besonders `N8N_ENCRYPTION_KEY`: Geht dieser Schlüssel verloren, sind **alle** in n8n gespeicherten Credentials (API-Keys, OAuth-Tokens, Datenbank-Verbindungen) **unwiederbringlich unentschlüsselbar**. Es gibt keine Wiederherstellung — nur ein neues, leeres n8n.

---

## Gepinnte Versionen

Alle Abhängigkeiten sind bewusst **fest versioniert** am Skriptanfang, statt mit `@latest` installiert zu werden. Grund: n8n veröffentlicht fast wöchentlich neue Minor-Versionen, und ein ungepinntes `@latest` kann durch ein Update von heute auf morgen den Aufbau brechen.

| Komponente | Version | Hinweis |
|------------|---------|---------|
| Node.js | `24.21.0` | Active LTS. n8n verlangt ≥ 20.19 |
| n8n | `2.41.6` | Stable-Kanal. **Nicht** 3.x — enthält Breaking Changes |
| crewai | `1.15.23` | |
| fastapi | `0.142.2` | |
| uvicorn | `0.53.0` | |

### Versionen aktualisieren

Die Pins stehen im Block am Anfang von `setup.sh`:

```bash
NODE_VERSION="24.21.0"
N8N_VERSION="2.41.6"
CREWAI_VERSION="1.15.23"
FASTAPI_VERSION="0.142.2"
UVICORN_VERSION="0.53.0"
```

Nach einer Änderung das Skript erneut ausführen. Es ist idempotent: vorhandene Services werden ersetzt, Datenbank und Zugangsdaten bleiben erhalten.

> **Hinweis zu n8n 3.0:** Die n8n-Changelog kündigt 3.0 für Oktober 2026 an. Ein Upgrade auf die 3.x-Reihe ist **kein einfacher Versionswechsel** — lies vor dem Update die [Breaking-Changes-Dokumentation](https://docs.n8n.io/changelog/v30-breaking-changes).

---

## Wichtige Umgebungsvariablen

Diese Variablen stehen in `/root/n8n/ecosystem.config.cjs` und werden von PM2 an n8n durchgereicht:

| Variable | Wert | Zweck |
|----------|------|-------|
| `N8N_ENCRYPTION_KEY` | generiert | **Pflicht.** Entschlüsselt gespeicherte Credentials |
| `N8N_LISTEN_ADDRESS` | `127.0.0.1` | Bindet n8n nur lokal — kein offener Port |
| `N8N_PROXY_HOPS` | `1` | Korrekte IP-Erkennung hinter dem Reverse Proxy |
| `N8N_EDITOR_BASE_URL` | `https://$DOMAIN/` | Editor-URL hinter dem Proxy |
| `N8N_SECURE_COOKIE` | `true` | Cookies nur über HTTPS |
| `N8N_WEBHOOK_URL` | `https://$DOMAIN/` | Basis-URL für Test- und Produktions-Webhooks |
| `N8N_UNVERIFIED_PACKAGES_ENABLED` | `false` | Installation ungeprüfter Community-Pakete unterbinden |
| `N8N_RUNNERS_TASK_TIMEOUT` | `300` | Task-Timeout in Sekunden |
| `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES` | `268435456` | Max. Entpackgröße: 256 MiB |
| `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES` | `1000` | Max. ZIP-Einträge beim Entpacken |
| `GENERIC_TIMEZONE` | Systemzeitzone | Zeitzone in n8n |
| `DB_POSTGRESDB_*` | generiert | Datenbankverbindung |

### Konfiguration anpassen

```bash
sudo nano /root/n8n/ecosystem.config.cjs
sudo pm2 restart n8n --update-env
```

### Warnungen beim Start von n8n

Beim ersten Start meldet n8n eine Reihe von Deprecation-Warnungen. Die wichtigsten davon und wie sie behandelt werden:

| Meldung | Bedeutung | Status |
|---------|-----------|--------|
| `WEBHOOK_URL -> Use N8N_WEBHOOK_URL instead` | Alte Variable, wird entfernt | ✅ **Gefixt** — das Skript setzt `N8N_WEBHOOK_URL` |
| `N8N_UNVERIFIED_PACKAGES_ENABLED ... will change to false` | Default ändert sich | ✅ Gefixt — explizit auf `false` gesetzt |
| `N8N_RUNNERS_TASK_TIMEOUT ... will be reduced from 300 to 60` | Default ändert sich | ✅ Gefixt — auf `300` festgeschrieben |
| `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES ... 2 GiB to 256 MiB` | Default wird kleiner | ✅ Gefixt — auf 256 MiB gesetzt |
| `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES ... 5000 to 1000` | Default wird kleiner | ✅ Gefixt — auf `1000` gesetzt |
| `Failed to start Python task runner in internal mode` | Bekannter n8n-Bug bei npm-Installation ([n8n-io/n8n#31149](https://github.com/n8n-io/n8n/issues/31149)) | ⚠️ Bekannt, nicht behoben |
| `Running n8n outside a container is deprecated` | Künftige Versionen verlangen Docker | ⚠️ Bewusste Entscheidung, siehe unten |

**Zum Python-Runner:** Diese Meldung betrifft ausschließlich den **Python-Code-Node** in n8n selbst. Sie tritt auf, weil n8n bei einer npm-Installation kein eigenes venv mitbringt — das offizielle Docker-Image liefert es mit. Alles andere funktioniert normal. Der separate **CrewAI-Service** dieses Setups ist davon **nicht** betroffen; er hat sein eigenes venv unter `/opt/agent_service/venv`.

**Zur Container-Warnung:** n8n hat den Betrieb außerhalb von Docker als veraltet eingestuft und kündigt an, dass künftige Versionen das offizielle Docker-Image voraussetzen. Dieses Setup nutzt bewusst **PM2 statt Docker**. Aktuell läuft n8n 2.41.6 problem damit. Sollte eine künftige n8n-Version die Installation ohne Container verweigern, ist ein Umstieg auf Docker Compose der nächste Schritt — die gepinnte `N8N_VERSION` im Skript macht ein solches Update planbar.

---

## Befehle für den Alltag

### n8N

```bash
pm2 status                              # Status aller PM2-Prozesse
pm2 logs n8n --lines 50                # Letzte 50 Logzeilen
pm2 logs n8n --err                     # Nur Fehler
pm2 restart n8n                        # Neustart
pm2 stop n8n                           # Stoppen
pm2 save                               # Aktuelle Prozessliste speichern
```

### CrewAI-Service

```bash
sudo systemctl status crewai
sudo systemctl restart crewai
sudo journalctl -u crewai -f           # Live-Logs
sudo systemctl cat crewai              # Unit inkl. Härtungsoptionen ansehen
sudo systemctl show crewai --property=User   # muss crewai ergeben, nicht root
id crewai                              # Rechte des Dienstusers prüfen
ls -la /opt/agent_service/.env         # muss root:crewai 640 sein
curl -sX POST http://127.0.0.1:8000/run-agent \
  -H 'Content-Type: application/json' \
  -d '{"topic":"Vorteile von n8n"}' | python3 -m json.tool
```

### API-Key (Nachschlagewerk)

Das Einrichten ist oben unter [Schritt 5](#5-api-key-eintragen-pflicht) beschrieben. Hier die Variablen und ihre Bedeutung:

| Variable | Bedeutung |
|----------|-----------|
| `ANTHROPIC_API_KEY` | Anthropic-API-Key. Pflicht — ohne ihn liefert `/run-agent` einen 500er. |
| `MODEL` | Modell-ID mit Provider-Präfix, z. B. `anthropic/claude-haiku-4-5`. Ohne Präfix fällt crewai auf LiteLLM zurück, das extra installiert werden müsste. |
| `MAX_TOKENS` | Obergrenze der Antwort. Bei Anthropic ein Pflichtparameter; Haiku 4.5 lässt 64000 zu, Default hier 8192. |

Die Datei muss `root:crewai 640` sein. Nach jeder Änderung an `.env` ein `systemctl restart crewai` — der laufende Prozess liest die Datei nur beim Start.

Die Antwort auf `/run-agent` enthält `model` und einen `usage`-Block mit `prompt_tokens`, `completion_tokens` und `total_tokens`, damit sich die Kosten eines Laufs ablesen lassen.

### Datenbank

```bash
sudo -u postgres psql -d n8n_db        # In die Datenbank einsteigen
sudo -u postgres psql -c '\l'          # Alle Datenbanken auflisten
sudo systemctl status postgresql
```

### Autostart prüfen

```bash
systemctl is-enabled pm2-root crewai postgresql
```

Alle drei sollten `enabled` ausgeben.

### Zustand nach einem Neustart prüfen

Nach einem Reboot sollte alles von selbst wiederkommen:

```bash
systemctl status crewai --no-pager | head -3
systemctl show crewai --property=User      # muss crewai sein, nicht root
ss -ltn | grep 8000                        # muss lauschen
```

Der erste Start nach einem Reboot dauert länger als der Folgestart — der Import von crewai erzeugt dann zum ersten Mal die `.pyc`-Dateien. Rechne hier mit 10 bis 20 Sekunden.

---

## Sicherheitshinweise

### Was das Skript tut

- ✅ Passwörter und `N8N_ENCRYPTION_KEY` werden am Ende ausgegeben **und** dauerhaft in einer `chmod 600`-Datei gesichert (`umask 077`), die nur für root lesbar ist
- ✅ n8n lauscht nur auf `127.0.0.1` — Port 5678 ist nicht öffentlich erreichbar
- ✅ SQL-Parameter werden über `psql -v` und `:'var'` übergeben statt per Heredoc-Interpolation
- ✅ Die Domain-Eingabe wird gegen ungültige Zeichen validiert
- ✅ Alle Passwörter sind 32 Zeichen alphanumerisch und werden deterministisch generiert
- ✅ SQL-Fehler führen zum Abbruch (`ON_ERROR_STOP=1`) statt zu einem stillen Weiterlaufen mit kaputter Datenbank
- ✅ Der Anthropic-API-Key steht ausschliesslich in der `.env` unter `/opt/agent_service` (ausserhalb jedes Webroots) — nie im Quelltext und damit nie in der Git-Historie
- ✅ Der CrewAI-Service läuft als eigener unprivilegierter Systemuser `crewai` mit `/usr/sbin/nologin`, nicht als root
- ✅ Die systemd-Unit nutzt `ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp` und weitere Härtungsoptionen; beschreibbar ist nur `/var/lib/crewai`

### Was du wissen solltest

> **ℹ️ Der CrewAI-Service läuft als Systemuser `crewai`.**
> Der FastAPI-Server führt von LLM-Agenten generierten Code aus — crewai interpretiert Modell-Ausgaben als Anweisungen. Deshalb läuft der Dienst nicht als root, sondern als eigener unprivilegierter Systemuser ohne Login-Shell. Die Unit setzt zusätzlich `ProtectSystem=strict` (nur `/var/lib/crewai` beschreibbar), `NoNewPrivileges`, `PrivateTmp` und `ProtectKernelTunables`.
>
> Das ist **Schadensbegrenzung, keine Sandbox**. Ein Fehler im Modell oder ein manipulierter Prompt kann den Dienst zum Absturz bringen und Daten unter `/var/lib/crewai` verändern — den Host und andere Dienste erreicht er damit nicht.
>
> n8n selbst läuft weiterhin über PM2 als root. Das ist eine bewusste Entscheidung des Setups: PM2 wird in [dieser Anleitung](https://docs.n8n.io/hosting/installation/npm/) für den Systemdienst verwendet und bringt kein eigenes Rechtekonzept mit. Für eine stärkere Isolierung wäre ein Container-Setup der nächste Schritt.
>
> Das ist Schadensbegrenzung, keine Sandbox. Ein Fehler im Modell kann den Dienst zum Absturz bringen, aber nicht mehr direkt den Host kompromittieren.
>
> Die `.env` mit dem API-Key liegt unter `/opt/agent_service` als `root:crewai` mit `640` — für root und die Dienstgruppe lesbar, für alle anderen nicht.

> **⚠️ Es werden keine Firewall-Regeln gesetzt.**
> Das Skript konfiguriert keine Firewall. Für einen Produktivbetrieb solltest du zusätzlich nur die nötigen Ports öffnen (22, 80, 443) und alle anderen schließen.

> **⚠️ Das PostgreSQL-Superuser-Passwort wird gesetzt.**
> Das Skript setzt das Passwort des Users `postgres`. Bei einer bestehenden Installation mit `peer`-Authentifizierung kann das die lokale Anmeldung verändern.

> **⚠️ Keine Datensicherung eingerichtet.**
> Das Skript richtet **keine** Backups ein. Richte vor dem Produktivbetrieb eine Sicherung der Datenbank `n8n_db` ein.

---

## Verhalten bei erneutem Lauf

Das Skript ist **idempotent** und kann gefahrlos mehrfach ausgeführt werden:

- **Passwörter werden wiederverwendet**, nicht neu generiert. Dadurch bleibt die bestehende Datenbankverbindung gültig
- **`N8N_ENCRYPTION_KEY` bleibt unverändert** — andernfalls wären alle gespeicherten Credentials verloren
- **Die Domain aus der Credentials-Datei wird als Standard angeboten**
- Bestehende Swap-Datei, Pakete und systemd-Unit werden erkannt und übersprungen
- PM2-Prozess `n8n` wird vor dem Neustart gelöscht und neu angelegt

Damit eignet sich das Skript auch, um **einzelne Komponenten zu aktualisieren**, ohne eine Neuinstallation zu machen.

---

## Fehlerbehebung

### Das Skript bricht sofort mit „Fehler in Zeile NNN" ab

Das Skript nutzt `set -euo pipefail` und einen ERR-Trap, der die fehlerhafte Zeile nennt. Prüfe die Ausgabe von `bash -x setup.sh` für eine vollständige Ablaufverfolgung.

### `pm2: command not found`

Nach der Node-Installation wurde der Pfad eventuell nicht neu eingelesen:

```bash
source /etc/profile.d/nvm.sh 2>/dev/null
export PATH="$PATH:$(npm root -g | sed 's|/node_modules$|/../bin|')"
hash -r
```

### n8n startet nicht

```bash
pm2 logs n8n --lines 100
pm2 status
```

Häufigste Ursache: die Datenbankverbindung schlägt fehl. Prüfe:

```bash
sudo -u postgres psql -c "SELECT 1 FROM pg_roles WHERE rolname='n8n_db';"
```

### `n8n läuft nicht` trotz erfolgreicher Installation

Der Zustand kann auch an einer falschen `N8N_ENCRYPTION_KEY` liegen — etwa wenn die Credentials-Datei zwischen zwei Läufen gelöscht wurde. Prüfe, ob die Datei existiert:

```bash
ls -l /root/n8n-setup-credentials.txt
```

Fehlt sie, erzeugt ein erneuter Lauf einen **neuen** Key. Nur sinnvoll, wenn n8n ohnehin neu aufgesetzt werden soll.

### n8n ist nicht erreichbar

Prüfe, ob der Reverse Proxy in aaPanel eingerichtet ist:

```bash
curl -I http://127.0.0.1:5678       # muss lokal antworten
```

Antwortet der Port lokal, aber nicht über die Domain, liegt der Fehler am Reverse Proxy oder am SSL-Zertifikat.

### Swap wurde nicht angelegt

```bash
swapon --show
grep swap /etc/fstab
```

Auf btrfs und einigen XFS-Setups wird `fallocate` nicht unterstützt; das Skript weicht dann automatisch auf `dd` aus.

---

## Projektstruktur

```
.
├── setup.sh                 # Das Setup-Skript für einen frischen Server
├── README.md                # Diese Datei
└── .gitattributes           # LF-Zeilenenden
```

`setup.sh` ist für **frische Server** gedacht und legt alles von Grund auf an. Bestehende Installationen damit erneut zu fahren überschreibt die vorhandenen Daten — bei n8n also die Workflows und bei PostgreSQL die Datenbank.

---

## Lizenz

Dieses Skript steht unter der [MIT-Lizenz](https://opensource.org/licenses/MIT).

---

## Verwandte Links

- [n8n Dokumentation](https://docs.n8n.io/)
- [n8n Changelog](https://docs.n8n.io/changelog)
- [CrewAI Dokumentation](https://docs.crewai.com/)
- [FastAPI Dokumentation](https://fastapi.tiangolo.com/)
- [aaPanel](https://www.aapanel.com/)
- [Node.js Releases](https://nodejs.org/en/about/previous-releases)
