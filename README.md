# 🦅 Frigate NVR — Auto Installer for Proxmox LXC

> **Italiano 🇮🇹** | **English 🇬🇧**

Installazione automatica di [Frigate NVR](https://frigate.video) in un container LXC su Proxmox, con supporto Google Coral USB TPU, storage esterno e configurazione completa.

Automatic installation of [Frigate NVR](https://frigate.video) inside a Proxmox LXC container, with Google Coral USB TPU support, external storage and full configuration.

---

## 📋 Indice / Table of Contents

- [Requisiti / Requirements](#-requisiti--requirements)
- [Architettura / Architecture](#-architettura--architecture)
- [Installazione / Installation](#-installazione--installation)
- [Aggiungere Telecamere / Add Cameras](#-aggiungere-telecamere--add-cameras)
- [Gestione / Management](#-gestione--management)
- [Risoluzione Problemi / Troubleshooting](#-risoluzione-problemi--troubleshooting)
- [Struttura File / File Structure](#-struttura-file--file-structure)

---

## ✅ Requisiti / Requirements

### IT 🇮🇹
- Proxmox VE 7.x o superiore
- Container LXC Debian 11/12 già creato
- Google Coral USB TPU (opzionale ma consigliato)
- Almeno **2GB RAM** e **2 CPU core** assegnati al container
- Connessione internet

### EN 🇬🇧
- Proxmox VE 7.x or higher
- Debian 11/12 LXC container already created
- Google Coral USB TPU (optional but recommended)
- At least **2GB RAM** and **2 CPU cores** assigned to the container
- Internet connection

---

## 🏗 Architettura / Architecture

```
┌─────────────────────────────────────────────────┐
│              PROXMOX HOST                        │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │         LXC Container (Debian)             │  │
│  │                                            │  │
│  │  ┌──────────────────────────────────────┐  │  │
│  │  │       Docker Container               │  │  │
│  │  │          Frigate NVR                 │  │  │
│  │  │   :5000 (Web UI)                     │  │  │
│  │  │   :8554 (RTSP restream)              │  │  │
│  │  └──────────────────────────────────────┘  │  │
│  │                                            │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│  [USB] Google Coral TPU ──────────────────────►  │
└─────────────────────────────────────────────────┘
         ▲                        ▲
    IP Cameras                 Storage
    (RTSP)                  (NAS / HDD)
```

---

## 🚀 Installazione / Installation

### STEP 1 — Proxmox Host

#### IT 🇮🇹
Esegui questo script dalla **shell di Proxmox** (non dal container!).
Configura automaticamente: RAM/CPU del container, passthrough USB Coral, disco esterno opzionale.

#### EN 🇬🇧
Run this script from the **Proxmox shell** (not from inside the container!).
Automatically configures: container RAM/CPU, Coral USB passthrough, optional external disk.

```bash
# Scarica / Download
wget https://raw.githubusercontent.com/ago19800/frigate-lxc-installer/main/proxmox_setup.sh

# Esegui / Run
bash proxmox_setup.sh
```

**Lo script farà / The script will:**

| IT | EN |
|----|----|
| Mostra lista container LXC | Show LXC container list |
| Configura RAM e CPU del container | Configure container RAM and CPU |
| Rileva Google Coral USB | Detect Google Coral USB |
| Aggiunge passthrough USB | Add USB passthrough |
| Crea servizio systemd per `/dev/bus/usb` | Create systemd service for `/dev/bus/usb` |
| Configura disco esterno (opzionale) | Configure external disk (optional) |
| Riavvia il container | Restart the container |

> ![Screenshot proxmox_setup.sh](.github/images/proxmox_setup.png)
> *Sostituisci questa immagine con lo screenshot reale / Replace with real screenshot*

---

### STEP 2 — Dentro il Container / Inside the Container

#### IT 🇮🇹
Entra nel container e lancia l'installer.

#### EN 🇬🇧
Enter the container and run the installer.

```bash
# Entra nel container / Enter container (dalla shell Proxmox / from Proxmox shell)
pct enter 103

# Scarica lo script / Download script
wget https://raw.githubusercontent.com/ago19800/frigate-lxc-installer/main/install_frigate.sh

# Esegui / Run
bash install_frigate.sh
```

**L'installer chiederà / The installer will ask:**

| Domanda / Question | Default | Note IT | Note EN |
|---|---|---|---|
| Storage per registrazioni | `/opt/frigate/storage` | Interno, esterno o personalizzato | Internal, external or custom |
| RAM per Docker | `2g` | Acepta: `2g`, `1500m`, `2048` | Accepts: `2g`, `1500m`, `2048` |
| CPU per Docker | core disponibili | Non può superare i core del container | Cannot exceed container cores |
| Versione Frigate | `stable` | stable / stable-tensorrt / dev | stable / stable-tensorrt / dev |
| Avviare subito | `S` | Avvia Frigate al termine | Start Frigate when done |

> ![Screenshot install_frigate.sh](.github/images/install_frigate.png)
> *Sostituisci questa immagine con lo screenshot reale / Replace with real screenshot*

---

### STEP 3 — Apri l'Interfaccia / Open the Interface

```
http://IP-CONTAINER:5000
```

> ![Screenshot interfaccia Frigate](.github/images/frigate_ui.png)
> *Sostituisci questa immagine con lo screenshot reale / Replace with real screenshot*

---

## 📷 Aggiungere Telecamere / Add Cameras

### IT 🇮🇹
Usa lo script interattivo oppure modifica manualmente il config.

### EN 🇬🇧
Use the interactive script or manually edit the config.

```bash
# Script guidato / Guided script
bash /opt/frigate/aggiungi_telecamera.sh

# Oppure / Or edit manually
nano /opt/frigate/config/config.yml
```

**Esempio config telecamera / Camera config example:**

```yaml
cameras:
  ingresso:
    ffmpeg:
      inputs:
        - path: rtsp://admin:password@192.168.1.100:554/stream
          roles:
            - detect
        - path: rtsp://admin:password@192.168.1.100:554/stream_sub
          roles:
            - record
    detect:
      enabled: true
      width: 1280
      height: 720
      fps: 5
    record:
      enabled: true
```

**Dopo aver modificato il config riavvia / After editing config restart:**

```bash
cd /opt/frigate && docker compose restart
```

---

## ⚙️ Configurazione Record H24 / 24h Recording Config

### IT 🇮🇹
Per Frigate 0.17+ la sezione `record` globale deve essere così:

### EN 🇬🇧
For Frigate 0.17+ the global `record` section must be:

```yaml
record:
  enabled: true
  sync_recordings: true
  continuous:
    days: 7       # Registra sempre H24 per 7 giorni / Always record H24 for 7 days
  motion:
    days: 7       # Registrazioni su movimento / Motion recordings
  alerts:
    retain:
      days: 30
      mode: motion
  detections:
    retain:
      days: 7
      mode: motion
```

> ⚠️ **IMPORTANTE / IMPORTANT:** In Frigate 0.17 il `retain` a livello telecamera non è più supportato. Usa solo `record: enabled: true` per ogni telecamera. / In Frigate 0.17 camera-level `retain` is no longer supported. Use only `record: enabled: true` per camera.

---

## 🛠 Gestione / Management

### IT 🇮🇹 | EN 🇬🇧

```bash
# Avvia / Start
bash /opt/frigate/start.sh

# Ferma / Stop
bash /opt/frigate/stop.sh

# Log in tempo reale / Live logs
bash /opt/frigate/logs.sh

# Stato container / Container status
bash /opt/frigate/status.sh

# Aggiorna immagine Docker / Update Docker image
bash /opt/frigate/update.sh
```

### Comandi Docker diretti / Direct Docker commands

```bash
cd /opt/frigate

# Riavvia / Restart
docker compose restart

# Ferma e riavvia / Stop and restart
docker compose down && docker compose up -d

# Log / Logs
docker logs frigate -f

# Statistiche uso risorse / Resource usage stats
docker stats frigate --no-stream
```

### Systemd

```bash
# IT: Controlla se parte all'avvio / EN: Check if starts on boot
systemctl status frigate

# IT: Abilita avvio automatico / EN: Enable autostart
systemctl enable frigate

# IT: Riavvia servizio / EN: Restart service
systemctl restart frigate
```

---

## 🔧 Risoluzione Problemi / Troubleshooting

### ❌ Container non parte dopo riavvio Proxmox / Container won't start after Proxmox reboot

**IT:** Il servizio `usb-bus-dir` crea `/dev/bus/usb` prima del container. Verifica che sia abilitato:

**EN:** The `usb-bus-dir` service creates `/dev/bus/usb` before the container. Verify it's enabled:

```bash
# Dalla shell Proxmox / From Proxmox shell
systemctl is-enabled usb-bus-dir.service
# Risposta attesa / Expected: enabled

systemctl status usb-bus-dir.service
# Risposta attesa / Expected: active (exited)
```

**IT:** Se non è abilitato / **EN:** If not enabled:

```bash
systemctl enable usb-bus-dir.service
systemctl start usb-bus-dir.service
```

---

### ❌ Registrazioni non visibili nell'interfaccia / Recordings not visible in UI

**IT:** Verifica che il DB sia nel posto giusto e che lo storage sia scrivibile.

**EN:** Verify the DB is in the right place and storage is writable.

```bash
# IT: Verifica DB / EN: Verify DB
ls -la /opt/frigate/config/frigate.db

# IT: Verifica file mp4 / EN: Verify mp4 files
find /opt/frigate/storage/recordings/ -name "*.mp4" | wc -l

# IT: Fix permessi / EN: Fix permissions
chmod -R 777 /opt/frigate/storage
chmod 666 /opt/frigate/config/frigate.db

# IT: Riavvia / EN: Restart
cd /opt/frigate && docker compose restart
```

---

### ❌ RAM non applicata / RAM not applied

**IT:** In container LXC, `deploy.resources` viene ignorato da Docker. Lo script usa `mem_limit` che funziona correttamente.

**EN:** In LXC containers, `deploy.resources` is silently ignored by Docker. The script uses `mem_limit` which works correctly.

```bash
# IT: Verifica RAM assegnata / EN: Verify assigned RAM
docker stats frigate --no-stream
# Colonna / Column: MEM USAGE / LIMIT → deve mostrare / should show: ... / 2GiB
```

**IT:** Se la RAM mostrata in Proxmox è ancora 512MB, assegnala dal pannello Proxmox oppure:

**EN:** If RAM shown in Proxmox is still 512MB, assign it from Proxmox panel or:

```bash
# Dalla shell Proxmox / From Proxmox shell
pct set 103 -memory 2048 -cores 2
```

---

### ❌ Coral TPU non rilevato / Coral TPU not detected

```bash
# IT: Verifica dalla shell Proxmox / EN: Verify from Proxmox shell
lsusb | grep -i "1a6e\|18d1"

# IT: Verifica dentro il container / EN: Verify inside container
ls /dev/bus/usb/

# IT: Verifica conf LXC / EN: Verify LXC conf
grep "usb" /etc/pve/lxc/103.conf
```

**IT:** Il file conf deve contenere / **EN:** The conf file must contain:
```
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.cgroup2.devices.allow: c 226:* rwm
```

---

### ❌ Errore config YAML / YAML config error

**IT:** Valida il config prima di riavviare:

**EN:** Validate config before restarting:

```bash
docker run --rm \
  -v /opt/frigate/config:/config \
  ghcr.io/blakeblackshear/frigate:stable \
  python3 -c "import yaml; yaml.safe_load(open('/config/config.yml'))" \
  && echo "Config OK" || echo "Config ERRORE"
```

---

## 📁 Struttura File / File Structure

```
/opt/frigate/
├── docker-compose.yml          # Config Docker Compose
├── config/
│   ├── config.yml              # Config Frigate (telecamere, record, ecc)
│   └── frigate.db              # Database SQLite (NON spostare!)
├── storage/
│   ├── recordings/             # Video registrazioni H24
│   ├── clips/                  # Clip eventi
│   └── exports/                # Export manuali
├── start.sh                    # Avvia Frigate
├── stop.sh                     # Ferma Frigate
├── logs.sh                     # Log in tempo reale
├── status.sh                   # Stato container
├── update.sh                   # Aggiorna immagine Docker
└── aggiungi_telecamera.sh      # Aggiungi telecamere

/etc/systemd/system/
└── frigate.service             # Servizio systemd (avvio automatico)

/etc/systemd/system/            # (su Proxmox host)
└── usb-bus-dir.service         # Garantisce /dev/bus/usb prima del container

/etc/pve/lxc/103.conf           # (su Proxmox host)
                                # Config LXC con passthrough USB
```

---

## 📊 Porte / Ports

| Porta / Port | Protocollo | Descrizione |
|---|---|---|
| `5000` | HTTP | Web UI Frigate |
| `8554` | RTSP | Restream telecamere via go2rtc |
| `8555` | TCP/UDP | WebRTC live view |

---

## 🔄 Aggiornare Frigate / Update Frigate

```bash
bash /opt/frigate/update.sh

# Oppure manualmente / Or manually
cd /opt/frigate
docker compose pull
docker compose up -d
docker image prune -f
```

---

## 📝 Note Versioni / Version Notes

| Frigate | Record Config | Note |
|---|---|---|
| ≤ 0.14 | `retain: mode: all` | Legacy |
| 0.15 - 0.16 | `retain: mode: all` + `events:` | |
| **0.17+** | `continuous:` + `motion:` + `alerts:` + `detections:` | **Attuale / Current** |

---

## 🤝 Contribuire / Contributing

**IT:** Pull request benvenute! Per bug gravi apri una Issue.

**EN:** Pull requests welcome! For serious bugs open an Issue.

---

## 📄 Licenza / License

MIT License — Usa liberamente / Use freely

---

## ⭐ Credits

- [Frigate NVR](https://frigate.video) — Blake Blackshear
- [Proxmox VE](https://proxmox.com)
- [Google Coral](https://coral.ai)
