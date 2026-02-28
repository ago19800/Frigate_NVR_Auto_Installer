#!/bin/bash

# ============================================================
#  🦅 FRIGATE AUTO-INSTALLER per Proxmox LXC + Docker
#  Supporto: Coral USB, storage esterno, risorse personalizzate
#  v2.6 - Fix config record per Frigate 0.17 (continuous/motion/alerts/detections)
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FRIGATE_DIR="/opt/frigate"
CONFIG_DIR="$FRIGATE_DIR/config"
STORAGE_DIR=""
CORAL_FOUND=false
CPU_LIMIT="1"
RAM_LIMIT="2g"
FRIGATE_VERSION="stable"

log_info()    { echo -e "  ${GREEN}[✔]${NC} $1"; }
log_warn()    { echo -e "  ${YELLOW}[⚠]${NC} $1"; }
log_error()   { echo -e "  ${RED}[✘]${NC} $1"; }
log_section() { echo -e "\n  ${CYAN}${BOLD}▶ $1${NC}\n"; }
ask()         { echo -e "  ${BOLD}[?]${NC} $1"; }

# ────────────────────────────────────────────────────────────
banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔════════════════════════════════════════════════════╗"
    echo "  ║   🦅 FRIGATE NVR - Auto Installer v2.0           ║"
    echo "  ║   Proxmox LXC | Coral USB | Docker Compose       ║"
    echo "  ╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Esegui come root!"
        exit 1
    fi
}

# ────────────────────────────────────────────────────────────
check_environment() {
    log_section "Verifica ambiente"

    # Siamo in Proxmox host? (errore)
    if command -v pveversion &>/dev/null; then
        log_error "Sei sul HOST Proxmox! Questo script va eseguito DENTRO il container LXC."
        log_error "Entra nel container con: pct enter <ID>"
        exit 1
    fi

    # Siamo in LXC?
    if grep -q "lxc" /proc/1/environ 2>/dev/null || \
       grep -q "container=lxc" /proc/1/environ 2>/dev/null || \
       [[ -f /run/container_type ]] || \
       systemd-detect-virt 2>/dev/null | grep -q lxc; then
        log_info "Ambiente: Proxmox LXC ✓"
    else
        log_info "Ambiente: Sistema standalone"
    fi

    DISTRO=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "Sconosciuto")
    log_info "Sistema: ${DISTRO}"
}

# ────────────────────────────────────────────────────────────
install_dependencies() {
    log_section "Installazione dipendenze"

    apt-get update -qq
    apt-get install -y -qq \
        curl wget \
        ca-certificates \
        gnupg lsb-release \
        usbutils \
        jq \
        > /dev/null 2>&1

    log_info "Dipendenze installate"
}

# ────────────────────────────────────────────────────────────
install_docker() {
    log_section "Installazione Docker"

    if command -v docker &>/dev/null; then
        DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
        log_info "Docker già installato (versione $DOCKER_VER)"
        return
    fi

    log_info "Download e installazione Docker CE..."
    curl -fsSL https://get.docker.com | sh > /dev/null 2>&1

    systemctl enable docker --quiet
    systemctl start docker

    log_info "Docker CE installato"
}

# ────────────────────────────────────────────────────────────
detect_coral() {
    log_section "Rilevamento Coral TPU (USB)"

    CORAL_FOUND=false

    # Verifica se /dev/bus/usb è disponibile (richiede config Proxmox)
    if [[ ! -d /dev/bus/usb ]]; then
        log_warn "/dev/bus/usb non disponibile."
        log_warn "Hai eseguito proxmox_setup.sh sul host e riavviato il container?"
        log_warn "Continuo in modalità CPU."
        return
    fi

    CORAL_USB=$(lsusb 2>/dev/null | grep -i "1a6e\|18d1" | head -1 || true)

    if [[ -n "$CORAL_USB" ]]; then
        log_info "Coral USB rilevato: ${CORAL_USB}"
        CORAL_FOUND=true

        # Installa runtime
        log_info "Installazione runtime Coral Edge TPU..."
        if [[ ! -f /etc/apt/sources.list.d/coral-edgetpu.list ]]; then
            echo "deb https://packages.cloud.google.com/apt coral-edgetpu-stable main" \
                | tee /etc/apt/sources.list.d/coral-edgetpu.list > /dev/null
            curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
                | apt-key add - > /dev/null 2>&1 || true
            apt-get update -qq 2>/dev/null || true
        fi
        apt-get install -y -qq libedgetpu1-std 2>/dev/null || \
            log_warn "Runtime Coral non installato dal repo — il container userà la sua versione interna."

        log_info "Coral configurato in modalità edgetpu"
    else
        log_warn "Coral non trovato — modalità CPU"
    fi
}

# ────────────────────────────────────────────────────────────
choose_storage() {
    log_section "Configurazione Storage Video"

    echo ""
    echo -e "  Dove vuoi salvare le registrazioni?"
    echo ""
    echo -e "  ${BOLD}[1]${NC} Storage interno del container (default: /opt/frigate/storage)"
    echo -e "  ${BOLD}[2]${NC} Disco esterno montato da Proxmox (es: /mnt/frigate-storage)"
    echo -e "  ${BOLD}[3]${NC} Percorso personalizzato"
    echo ""
    ask "Scelta [1-3]:"
    read -r storage_choice

    case "$storage_choice" in
        2)
            # Mostra mount point disponibili
            echo ""
            log_info "Mount point disponibili nel container:"
            df -h | grep -E "^/dev|/mnt|/media" | awk '{print "  "$6" ("$2" totale, "$4" liberi)"}' || true
            echo ""
            ask "Inserisci il percorso del disco esterno (es: /mnt/frigate-storage):"
            read -r ext_path
            if [[ -z "$ext_path" ]]; then
                log_warn "Percorso vuoto, uso il default."
                STORAGE_DIR="$FRIGATE_DIR/storage"
            else
                STORAGE_DIR="$ext_path"
            fi
            ;;
        3)
            ask "Inserisci il percorso personalizzato:"
            read -r custom_path
            STORAGE_DIR="${custom_path:-$FRIGATE_DIR/storage}"
            ;;
        *)
            STORAGE_DIR="$FRIGATE_DIR/storage"
            ;;
    esac

    mkdir -p "$STORAGE_DIR"
    log_info "Storage: ${STORAGE_DIR}"
}

# ────────────────────────────────────────────────────────────
choose_resources() {
    log_section "Risorse (CPU & RAM)"

    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    TOTAL_CORES=$(nproc)

    echo ""
    echo -e "  RAM totale:  ${TOTAL_RAM_MB} MB"
    echo -e "  CPU cores:   ${TOTAL_CORES}"
    echo ""

    ask "RAM per Frigate? (es: 2g, 1500m, 2048 = MB interi) [default: 2g]:"
    read -r ram_input
    ram_input=$(echo "${ram_input,,}" | tr -d ' ')
    if [[ "$ram_input" =~ ^[0-9]+(m|g)$ ]]; then
        RAM_LIMIT="$ram_input"
    elif [[ "$ram_input" =~ ^[0-9]+$ ]]; then
        # numero puro = MB
        RAM_LIMIT="${ram_input}m"
        log_info "Interpretato come ${ram_input}MB"
    else
        RAM_LIMIT="2g"
        log_warn "Formato non valido, uso default 2g"
    fi

    ask "CPU per Frigate? (es: 2, 1.5) [default: ${TOTAL_CORES}]:"
    read -r cpu_input
    cpu_input=$(echo "$cpu_input" | tr -d ' ')
    if [[ "$cpu_input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if awk "BEGIN{exit !($cpu_input > $TOTAL_CORES)}"; then
            log_warn "Valore $cpu_input supera i core disponibili ($TOTAL_CORES). Uso $TOTAL_CORES."
            CPU_LIMIT="$TOTAL_CORES"
        else
            CPU_LIMIT="$cpu_input"
        fi
    else
        CPU_LIMIT="$TOTAL_CORES"
    fi

    log_info "RAM: ${RAM_LIMIT} | CPU: ${CPU_LIMIT}"
}

# ────────────────────────────────────────────────────────────
choose_version() {
    log_section "Versione Frigate"

    echo ""
    echo -e "  ${BOLD}[1]${NC} stable       (consigliato)"
    echo -e "  ${BOLD}[2]${NC} stable-tensorrt  (NVIDIA GPU)"
    echo -e "  ${BOLD}[3]${NC} dev          (ultima, meno stabile)"
    echo ""
    ask "Versione [1-3, default: 1]:"
    read -r ver_choice

    case "$ver_choice" in
        2) FRIGATE_VERSION="stable-tensorrt" ;;
        3) FRIGATE_VERSION="dev" ;;
        *) FRIGATE_VERSION="stable" ;;
    esac

    log_info "Versione: ${FRIGATE_VERSION}"
}

# ────────────────────────────────────────────────────────────
create_config() {
    log_section "Creazione config.yml"

    mkdir -p "$CONFIG_DIR"
    mkdir -p "$STORAGE_DIR/recordings" "$STORAGE_DIR/clips" "$STORAGE_DIR/exports"
    chmod -R 755 "$FRIGATE_DIR"
    chmod -R 777 "$STORAGE_DIR"

    if [[ "$CORAL_FOUND" == true ]]; then
        DETECTOR_BLOCK="detectors:
  coral:
    type: edgetpu
    device: usb"
    else
        DETECTOR_BLOCK="detectors:
  cpu1:
    type: cpu
    num_threads: 3"
    fi

    cat > "$CONFIG_DIR/config.yml" << EOF
# ============================================================
#  Frigate NVR - Configurazione generata automaticamente
#  Data: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

mqtt:
  enabled: false

# ── Detector ───────────────────────────────────────────────
${DETECTOR_BLOCK}

# ── Database ───────────────────────────────────────────────
database:
  path: /config/frigate.db

# ── Registrazioni ──────────────────────────────────────────
record:
  enabled: true
  sync_recordings: true
  continuous:
    days: 7          # registra sempre H24 per 7 giorni
  motion:
    days: 7          # registrazioni su movimento per 7 giorni
  alerts:
    retain:
      days: 30
      mode: motion
  detections:
    retain:
      days: 7
      mode: motion

# ── Snapshot ───────────────────────────────────────────────
snapshots:
  enabled: true
  retain:
    default: 10

# ── Oggetti da rilevare ────────────────────────────────────
objects:
  track:
    - person
    - car
    - dog
    - cat

# ── FFmpeg ─────────────────────────────────────────────────
ffmpeg:
  hwaccel_args: []

# ── Telecamere ─────────────────────────────────────────────
# IMPORTANTE: Aggiungi le tue telecamere qui prima di avviare!
# Esempio:
# cameras:
#   telecamera1:
#     ffmpeg:
#       inputs:
#         - path: rtsp://utente:password@192.168.1.100:554/stream
#           roles:
#             - detect
#             - record
#     detect:
#       width: 1920
#       height: 1080
#       fps: 5
#
# Senza telecamere Frigate si avvia ma non fa nulla.
# Modifica questo file e poi: docker compose restart
cameras: {}
EOF

    log_info "config.yml creato"
}

# ────────────────────────────────────────────────────────────
create_docker_compose() {
    log_section "Creazione docker-compose.yml"

    if [[ -f "$FRIGATE_DIR/docker-compose.yml" ]]; then
        log_warn "docker-compose.yml esistente trovato — verrà sovrascritto con i nuovi valori."
        cp "$FRIGATE_DIR/docker-compose.yml" "$FRIGATE_DIR/docker-compose.yml.bak"
        log_info "Backup salvato in docker-compose.yml.bak"
    fi

    # Sezione devices: usa tutta la directory /dev/bus/usb
    if [[ "$CORAL_FOUND" == true ]]; then
        DEVICES_BLOCK="    devices:
      - /dev/bus/usb:/dev/bus/usb"
    else
        DEVICES_BLOCK="    # devices:
    #   - /dev/bus/usb:/dev/bus/usb  # Decommentare quando Coral è disponibile"
    fi

    cat > "$FRIGATE_DIR/docker-compose.yml" << EOF
# ============================================================
#  Frigate NVR - Docker Compose
#  Generato il $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

services:
  frigate:
    container_name: frigate
    image: ghcr.io/blakeblackshear/frigate:${FRIGATE_VERSION}
    restart: unless-stopped
    privileged: true
    mem_limit: ${RAM_LIMIT}
    cpus: ${CPU_LIMIT}

    shm_size: "512mb"

${DEVICES_BLOCK}

    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${CONFIG_DIR}:/config
      - ${STORAGE_DIR}:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 2000000000

    ports:
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"

    environment:
      FRIGATE_RTSP_PASSWORD: "frigate"
      TZ: "Europe/Rome"

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    log_info "docker-compose.yml creato"
}

# ────────────────────────────────────────────────────────────
create_scripts() {
    log_section "Script di gestione"

    cat > "$FRIGATE_DIR/start.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "🦅 Avvio Frigate..."
docker compose up -d
echo "✔ Apri: http://$(hostname -I | awk '{print $1}'):5000"
EOF

    cat > "$FRIGATE_DIR/stop.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
docker compose down
EOF

    cat > "$FRIGATE_DIR/logs.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
docker compose logs -f frigate
EOF

    cat > "$FRIGATE_DIR/update.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
docker compose pull
docker compose up -d
docker image prune -f
EOF

    cat > "$FRIGATE_DIR/status.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
docker compose ps
docker stats frigate --no-stream 2>/dev/null || true
EOF

    cat > "$FRIGATE_DIR/aggiungi_telecamera.sh" << 'CAMEOF'
#!/bin/bash
# Script helper per aggiungere telecamere al config
CONFIG="/opt/frigate/config/config.yml"

echo ""
echo "=== AGGIUNGI TELECAMERA ==="
echo ""
read -p "Nome telecamera (es: ingresso): " CAM_NAME
read -p "IP telecamera (es: 192.168.1.100): " CAM_IP
read -p "Utente RTSP (es: admin): " CAM_USER
read -p "Password RTSP: " CAM_PASS
read -p "Path stream (es: /stream o /h264Preview_01_main): " CAM_PATH
read -p "Larghezza risoluzione (es: 1920): " CAM_W
read -p "Altezza risoluzione (es: 1080): " CAM_H

RTSP_URL="rtsp://${CAM_USER}:${CAM_PASS}@${CAM_IP}:554${CAM_PATH}"

# Rimuovi "cameras: {}" se presente
sed -i 's/^cameras: {}$/cameras:/' "$CONFIG"

cat >> "$CONFIG" << EOF

  ${CAM_NAME}:
    ffmpeg:
      inputs:
        - path: ${RTSP_URL}
          roles:
            - detect
            - record
    detect:
      width: ${CAM_W}
      height: ${CAM_H}
      fps: 5
EOF

echo ""
echo "✔ Telecamera '${CAM_NAME}' aggiunta!"
echo "  Riavvia Frigate con: bash /opt/frigate/start.sh"
CAMEOF

    chmod +x "$FRIGATE_DIR"/*.sh
    log_info "Script creati in $FRIGATE_DIR/"
}

# ────────────────────────────────────────────────────────────
create_systemd() {
    log_section "Servizio systemd"

    cat > /etc/systemd/system/frigate.service << EOF
[Unit]
Description=Frigate NVR
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${FRIGATE_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable frigate.service --quiet

    # Se era già attivo, riavvialo per applicare le modifiche
    if systemctl is-active frigate.service --quiet 2>/dev/null; then
        systemctl restart frigate.service
        log_info "Servizio systemd riavviato con nuova config"
    fi

    log_info "Servizio systemd configurato correttamente"
}

# ────────────────────────────────────────────────────────────
start_frigate() {
    log_section "Avvio Frigate"

    # Verifica permessi prima di avviare
    chmod -R 777 "$STORAGE_DIR" 2>/dev/null || true
    chmod -R 755 "$CONFIG_DIR" 2>/dev/null || true
    [ -f "$CONFIG_DIR/frigate.db" ] && chmod 666 "$CONFIG_DIR/frigate.db" || true

    cd "$FRIGATE_DIR"
    log_info "Download immagine Docker (attendere)..."
    docker compose pull

    log_info "Avvio container..."
    docker compose up -d

    sleep 8

    if docker ps | grep -q "frigate"; then
        STATUS=$(docker inspect frigate --format='{{.State.Status}}' 2>/dev/null)
        if [[ "$STATUS" == "running" ]]; then
            log_info "Frigate avviato! ✅"
        else
            log_warn "Container in stato: $STATUS — controlla i log"
        fi
    fi
}

# ────────────────────────────────────────────────────────────
print_summary() {
    LOCAL_IP=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${CYAN}${BOLD}  ═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  ✅  INSTALLAZIONE COMPLETATA!${NC}"
    echo -e "${CYAN}${BOLD}  ═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}🌐 Interfaccia Web:${NC}   ${CYAN}http://${LOCAL_IP}:5000${NC}"
    echo -e "  ${BOLD}📁 Installazione:${NC}     ${FRIGATE_DIR}"
    echo -e "  ${BOLD}⚙️  Config:${NC}            ${CONFIG_DIR}/config.yml"
    echo -e "  ${BOLD}💾 Storage:${NC}           ${STORAGE_DIR}"
    if [[ "$CORAL_FOUND" == true ]]; then
        echo -e "  ${BOLD}🔌 Coral TPU:${NC}         Attivo (edgetpu) ✅"
    else
        echo -e "  ${BOLD}🔌 Coral TPU:${NC}         Non rilevato (CPU mode)"
    fi
    echo ""
    echo -e "  ${BOLD}📋 Comandi utili:${NC}"
    echo -e "     ${YELLOW}bash $FRIGATE_DIR/start.sh${NC}              avvia"
    echo -e "     ${YELLOW}bash $FRIGATE_DIR/stop.sh${NC}               ferma"
    echo -e "     ${YELLOW}bash $FRIGATE_DIR/logs.sh${NC}               log live"
    echo -e "     ${YELLOW}bash $FRIGATE_DIR/aggiungi_telecamera.sh${NC} aggiungi cam"
    echo ""
    echo -e "  ${YELLOW}⚠️  PASSO SUCCESSIVO:${NC}"
    echo -e "     Aggiungi le telecamere con:"
    echo -e "     ${YELLOW}bash $FRIGATE_DIR/aggiungi_telecamera.sh${NC}"
    echo -e "     oppure modifica manualmente:"
    echo -e "     ${YELLOW}nano $CONFIG_DIR/config.yml${NC}"
    echo ""
    echo -e "${CYAN}${BOLD}  ═══════════════════════════════════════════════════════${NC}"
    echo ""
}

# ────────────────────────────────────────────────────────────
#  MAIN
# ────────────────────────────────────────────────────────────
main() {
    banner
    check_root
    check_environment

    echo -e "  Installa Frigate NVR con Docker in modo completamente automatico."
    echo ""
    ask "Premere INVIO per continuare o Ctrl+C per annullare..."
    read -r

    install_dependencies
    install_docker
    detect_coral
    choose_storage
    choose_resources
    choose_version

    mkdir -p "$FRIGATE_DIR" "$CONFIG_DIR"

    create_config
    create_docker_compose
    create_scripts
    create_systemd

    echo ""
    ask "Avviare Frigate ora? [S/n]:"
    read -r avvia
    avvia=${avvia,,}
    if [[ "$avvia" != "n" ]]; then
        start_frigate
    else
        log_info "Per avviare: ${CYAN}bash $FRIGATE_DIR/start.sh${NC}"
    fi

    print_summary
}

main "$@"
