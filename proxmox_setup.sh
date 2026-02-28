#!/bin/bash

# ============================================================
#  🖥️  PROXMOX HOST SETUP - Frigate + Coral USB
#  Da eseguire sulla SHELL di Proxmox (non nel container!)
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "  ${GREEN}[✔]${NC} $1"; }
log_warn()    { echo -e "  ${YELLOW}[⚠]${NC} $1"; }
log_error()   { echo -e "  ${RED}[✘]${NC} $1"; }
log_section() { echo -e "\n  ${CYAN}${BOLD}▶ $1${NC}\n"; }
ask()         { echo -e "  ${BOLD}[?]${NC} $1"; }

clear
echo -e "${CYAN}${BOLD}"
echo "  ╔════════════════════════════════════════════════════╗"
echo "  ║   🖥️  PROXMOX SETUP - Frigate + Coral USB         ║"
echo "  ║   Da eseguire sulla shell HOST di Proxmox         ║"
echo "  ╚════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Verifica che siamo su Proxmox host ──────────────────────
log_section "Verifica ambiente"

if ! command -v pveversion &>/dev/null; then
    log_error "Questo script deve essere eseguito sul HOST Proxmox, non dentro un container!"
    log_error "Entra nella shell di Proxmox (non quella del container LXC)."
    exit 1
fi

log_info "Proxmox rilevato: $(pveversion | head -1)"

# ── Lista container disponibili ─────────────────────────────
log_section "Container LXC disponibili"

echo ""
pct list
echo ""

echo -e "  ${BOLD}[?]${NC} Inserisci l'ID del container dove installerai Frigate:"
read -r CT_ID

if [[ -z "$CT_ID" ]] || ! pct config "$CT_ID" &>/dev/null; then
    log_error "Container ID '$CT_ID' non trovato!"
    exit 1
fi

CT_CONF="/etc/pve/lxc/${CT_ID}.conf"
log_info "Container selezionato: $CT_ID"
log_info "File config: $CT_CONF"

# ── Configurazione RAM e CPU del container LXC ──────────────
log_section "Configurazione RAM e CPU container LXC"

CURRENT_MEM=$(grep "^memory:" "$CT_CONF" 2>/dev/null | awk '{print $2}' || echo "512")
CURRENT_CORES=$(grep "^cores:" "$CT_CONF" 2>/dev/null | awk '{print $2}' || echo "1")

echo ""
echo -e "  RAM attuale:   ${CURRENT_MEM} MB"
echo -e "  CPU attuale:   ${CURRENT_CORES} core"
echo ""
echo -e "  ${YELLOW}Frigate consiglia almeno 2048 MB RAM e 2 CPU core.${NC}"
echo ""

ask "Quanta RAM assegnare al container LXC? (in MB, es: 2048) [default: 2048]:"
read -r lxc_ram
lxc_ram=$(echo "$lxc_ram" | tr -d ' ')
if [[ "$lxc_ram" =~ ^[0-9]+$ ]] && [[ "$lxc_ram" -ge 512 ]]; then
    LXC_RAM="$lxc_ram"
else
    LXC_RAM="2048"
    log_warn "Valore non valido, uso 2048 MB"
fi

ask "Quanti CPU core assegnare al container LXC? [default: 2]:"
read -r lxc_cores
lxc_cores=$(echo "$lxc_cores" | tr -d ' ')
if [[ "$lxc_cores" =~ ^[0-9]+$ ]] && [[ "$lxc_cores" -ge 1 ]]; then
    LXC_CORES="$lxc_cores"
else
    LXC_CORES="2"
    log_warn "Valore non valido, uso 2 core"
fi

# Applica con pct set
log_info "Imposto RAM: ${LXC_RAM} MB | CPU: ${LXC_CORES} core..."
pct set "$CT_ID" -memory "$LXC_RAM" -cores "$LXC_CORES"
log_info "RAM e CPU aggiornati nel container LXC ✅"

# ── Rilevamento Coral USB ───────────────────────────────────
log_section "Rilevamento Coral TPU (USB)"

CORAL_USB=$(lsusb 2>/dev/null | grep -i "1a6e\|18d1" | head -1 || true)

if [[ -n "$CORAL_USB" ]]; then
    log_info "Coral USB rilevato: ${CORAL_USB}"
    BUS=$(echo "$CORAL_USB" | awk '{print $2}')
    DEV=$(echo "$CORAL_USB" | awk '{print $4}' | tr -d ':')
    log_info "Bus: $BUS, Device: $DEV"
else
    log_warn "Coral USB non rilevato. Configurerò comunque il passthrough USB generico."
fi

# ── Verifica se già configurato ─────────────────────────────
log_section "Configurazione passthrough USB nel container"

if grep -q "dev/bus/usb" "$CT_CONF" 2>/dev/null; then
    log_warn "Passthrough USB già presente in $CT_CONF — salto configurazione."
else
    log_info "Aggiunta configurazione passthrough USB..."

    cat >> "$CT_CONF" << 'EOF'
# Frigate - Coral USB passthrough
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.cgroup2.devices.allow: c 226:* rwm
EOF

    log_info "Configurazione aggiunta a $CT_CONF"
fi

# ── Fix: Crea /dev/bus/usb all'avvio di Proxmox ────────────
log_section "Fix avvio automatico USB (Coral)"

# Crea la directory subito se non esiste
mkdir -p /dev/bus/usb
log_info "Directory /dev/bus/usb creata"

# Crea regola udev per creare /dev/bus/usb automaticamente
cat > /etc/udev/rules.d/99-usb-bus.rules << 'UDEVEOF'
# Crea /dev/bus/usb se non esiste (necessario per Coral in LXC)
SUBSYSTEM=="usb", ACTION=="add", RUN+="/bin/mkdir -p /dev/bus/usb"
UDEVEOF

udevadm control --reload-rules 2>/dev/null || true
log_info "Regola udev creata"

# Crea servizio systemd che garantisce /dev/bus/usb prima dell'avvio LXC
cat > /etc/systemd/system/usb-bus-dir.service << 'SVCEOF'
[Unit]
Description=Crea /dev/bus/usb per passthrough Coral in LXC
Before=pve-container@103.service
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/bin/mkdir -p /dev/bus/usb
ExecStart=/bin/chmod 755 /dev/bus/usb
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

# Sostituisci 103 con l'ID del container scelto
sed -i "s/pve-container@103/pve-container@${CT_ID}/" /etc/systemd/system/usb-bus-dir.service

systemctl daemon-reload
systemctl enable usb-bus-dir.service --quiet
log_info "Servizio systemd usb-bus-dir abilitato — /dev/bus/usb sarà creato ad ogni avvio"

# ── Passthrough disco esterno (opzionale) ───────────────────
log_section "Disco esterno per registrazioni (opzionale)"

echo ""
echo -e "  Vuoi montare un disco esterno nel container per le registrazioni?"
echo -e "  ${BOLD}[1]${NC} Sì, voglio usare un disco esterno"
echo -e "  ${BOLD}[2]${NC} No, uso lo storage interno del container"
echo ""
echo -e "  ${BOLD}[?]${NC} Scelta [1-2]:"
read -r disk_choice

if [[ "$disk_choice" == "1" ]]; then
    echo ""
    echo -e "  Dischi disponibili su Proxmox:"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL | grep -v loop
    echo ""
    echo -e "  ${BOLD}[?]${NC} Percorso del disco sull'host (es: /mnt/pve/disco, /dev/sdb1):"
    read -r HOST_DISK_PATH

    if [[ -z "$HOST_DISK_PATH" ]]; then
        log_warn "Percorso vuoto, salto configurazione disco esterno."
    else
        # Assicurati che sia montato
        if ! mountpoint -q "$HOST_DISK_PATH" 2>/dev/null; then
            log_warn "$HOST_DISK_PATH non sembra montato. Provo comunque..."
        fi

        CT_MOUNT_POINT="/mnt/frigate-storage"
        log_info "Aggiunta mount point: $HOST_DISK_PATH → container:$CT_MOUNT_POINT"

        # Aggiungi mount point tramite pct
        NEXT_MP=$(grep -c "^mp[0-9]" "$CT_CONF" 2>/dev/null || echo "0")
        echo "mp${NEXT_MP}: ${HOST_DISK_PATH},mp=${CT_MOUNT_POINT}" >> "$CT_CONF"

        log_info "Mount point mp${NEXT_MP} aggiunto"
        log_warn "Dentro il container il disco sarà disponibile in: $CT_MOUNT_POINT"
    fi
fi

# ── Riavvio container ───────────────────────────────────────
log_section "Riavvio container"

echo -e "  ${BOLD}[?]${NC} Vuoi riavviare il container $CT_ID ora per applicare le modifiche? [S/n]:"
read -r restart_choice
restart_choice=${restart_choice,,}

if [[ "$restart_choice" != "n" ]]; then
    log_info "Riavvio container $CT_ID..."
    pct stop "$CT_ID" 2>/dev/null || true
    sleep 3
    pct start "$CT_ID"
    sleep 5
    log_info "Container $CT_ID riavviato!"
else
    log_warn "Ricordati di riavviare manualmente il container prima di installare Frigate!"
    log_warn "Comando: pct stop $CT_ID && pct start $CT_ID"
fi

# ── Riepilogo ───────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}  ═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✅  PROXMOX CONFIGURATO!${NC}"
echo -e "${CYAN}${BOLD}  ═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Passo successivo:${NC}"
echo -e "  Entra nel container $CT_ID e lancia:"
echo -e "  ${YELLOW}bash install_frigate.sh${NC}"
echo ""
echo -e "  Per entrare nel container:"
echo -e "  ${YELLOW}pct enter $CT_ID${NC}"
echo ""
