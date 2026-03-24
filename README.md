<div align="center">

```
███████╗██╗      █████╗ ██████╗ ███████╗
██╔════╝██║     ██╔══██╗██╔══██╗██╔════╝
█████╗  ██║     ███████║██████╔╝█████╗  
██╔══╝  ██║     ██╔══██║██╔══██╗██╔══╝  
██║     ███████╗██║  ██║██║  ██║███████╗
╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝
                NODE AGENT BY SHADOW_LAY
```

**Agente de nodo para el sistema distribuido Flare**  
*Se conecta al master, recibe órdenes y ejecuta scripts automáticamente*

![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=flat-square&logo=linux&logoColor=black)
![Docker](https://img.shields.io/badge/Docker-2496ED?style=flat-square&logo=docker&logoColor=white)
![LXC](https://img.shields.io/badge/LXC-333333?style=flat-square&logo=linux-containers&logoColor=white)

</div>

---

## ¿Qué es Flare Node?

`flare-node` es el agente que se instala en cada servidor que quieras controlar desde el panel. Una vez instalado, el nodo se **registra automáticamente** en el master y empieza a recibir y ejecutar tareas — sin necesidad de configurar nada en el master, sin abrir puertos extra, sin tocar firewalls.

### ¿Cómo funciona la comunicación?

> **El nodo siempre habla primero.** No es el master quien empuja órdenes al nodo, sino el nodo quien pregunta periódicamente al master si hay algo que ejecutar.

```
 MASTER                          NODO
   │                              │
   │   ← POST /api/agent/poll     │  "¿Hay tarea para mí?"
   │                              │
   │   { task: { command, time } }│  "Sí, ejecuta esto"
   │ ─────────────────────────── ►│
   │                              │  [ejecuta el comando]
   │   ← POST /api/agent/complete │  "Terminé"
   │                              │
   │   ← POST /api/agent/poll     │  "¿Hay algo más?"
   │   { task: null }             │  "Por ahora no"
   │ ─────────────────────────── ►│
```

**Ventajas de este modelo:**
- El nodo no necesita IP pública ni abrir puertos
- Funciona detrás de NAT, firewalls, y dentro de contenedores
- Si el master se cae, el nodo espera y reconecta solo
- Si el nodo se reinicia, se re-registra solo en el master

---

## Requisitos

| Requisito | Mínimo |
|-----------|--------|
| OS | Debian / Ubuntu / Alpine / cualquier Linux con bash |
| RAM | 64 MB libres |
| Disco | 50 MB |
| Red | Acceso saliente HTTP al master (puerto 80 o el que uses) |
| Usuario | `root` (para instalar el servicio de autostart) |
| Dependencias | `curl`, `bash`, `bc` — el installer las instala automáticamente |

**Entornos soportados:**
- ✅ VPS / Servidor dedicado (systemd)
- ✅ Contenedor Docker
- ✅ Contenedor LXC / LXD
- ✅ OpenVZ (con crontab fallback)

---

## Instalación rápida

### 1 — Descarga y ejecuta el installer

```bash
wget https://raw.githubusercontent.com/flaresamp/flare-node/main/install-node.sh
sudo bash install-node.sh
```

O en una línea:

```bash
curl -fsSL https://raw.githubusercontent.com/flaresamp/flare-node/main/install-node.sh | sudo bash
```

### 2 — El installer te pedirá 3 datos

```
  IP o dominio del Master (ej: 1.2.3.4 o panel.ejemplo.com): 45.76.123.10
  AGENT_TOKEN (del master): a1b2c3d4e5f6...
  Nombre del nodo [node-mi-server]: nodo-usa-1
```

> **¿Dónde está el AGENT_TOKEN?**  
> En el master, está guardado en `/opt/master/.env`. También se mostró al final de la instalación del master.
> ```bash
> # En el master:
> cat /opt/master/.env
> ```

### 3 — Listo

En ~5 segundos el nodo aparece en el panel del master con su IP, país, CPU y RAM.

---

## Estructura de archivos

Después de instalar, estos son los archivos que crea el agente:

```
/opt/node-agent/
│
├── agent.conf          ← Configuración editable
├── agent.sh            ← El agente principal (no editar)
├── start.sh            ← Wrapper para Docker ENTRYPOINT
│
└── scripts/            ← TU CARPETA — pon aquí tus scripts
    ├── README.txt
    └── example.sh
```

---

## Configuración (`agent.conf`)

El archivo de configuración está en `/opt/node-agent/agent.conf`. Puedes editarlo en cualquier momento y reiniciar el servicio para aplicar los cambios.

```ini
# ============================================================
#  NODE AGENT CONFIGURATION
# ============================================================

# URL del Master Panel (sin barra final)
# Ejemplos:
#   MASTER_URL=http://45.76.123.10
#   MASTER_URL=http://panel.tudominio.com
#   MASTER_URL=https://panel.tudominio.com
MASTER_URL=http://45.76.123.10

# Token de autenticación — debe coincidir con el AGENT_TOKEN del master
AGENT_TOKEN=a1b2c3d4e5f6...

# ID único del nodo — NO cambiar, identifica al nodo en la base de datos
NODE_ID=node_abc123def456

# Nombre visible en el panel del master
NODE_NAME=nodo-usa-1

# Intervalo de polling en segundos (recomendado: 3-5)
POLL_INTERVAL=3

# Carpeta donde están los scripts
SCRIPTS_DIR=/opt/node-agent/scripts

# Timeout de conexión al master en segundos
CONNECT_TIMEOUT=10
```

### Cambiar la IP del master

```bash
nano /opt/node-agent/agent.conf
# Edita la línea: MASTER_URL=http://NUEVA_IP

# Reinicia el servicio:
systemctl restart node-agent        # VPS
supervisorctl restart agent          # Container con supervisor
```

### Cambiar el nombre del nodo

```bash
nano /opt/node-agent/agent.conf
# Edita la línea: NODE_NAME=nuevo-nombre

systemctl restart node-agent
```

---

## Scripts — Cómo agregar herramientas

La carpeta `/opt/node-agent/scripts/` es donde colocas los scripts que el master va a ordenar ejecutar. El master construye el comando completo basándose en el método configurado en el panel, y el nodo lo ejecuta dentro de esa carpeta.

### Tipos de scripts soportados

| Tipo | Ejemplo de comando enviado por el master |
|------|------------------------------------------|
| **Bash / binario** | `./mi_script.sh 1.2.3.4 80 60` |
| **Python** | `python3 flooder.py -h 1.2.3.4 -p 80 -t 60` |
| **Node.js** | `node layer7.js https://ejemplo.com 60` |

### Ejemplo — agregar un script

```bash
# 1. Copia tu script a la carpeta
cp mi_herramienta.py /opt/node-agent/scripts/

# 2. Dale permisos de ejecución (si es bash/binario)
chmod +x /opt/node-agent/scripts/mi_herramienta.sh

# 3. En el panel del master, crea un método con:
#    Tipo: L4 o L7
#    Función: python / file / node
#    Archivo: mi_herramienta.py
#    Argumentos: -h {ip} -p {port} -t {time}
#
# El nodo ejecutará automáticamente:
#    python3 mi_herramienta.py -h 1.2.3.4 -p 80 -t 60
```

### Variables disponibles en los argumentos del método

| Variable | Se reemplaza por |
|----------|-----------------|
| `{ip}` | IP del objetivo |
| `{url}` | URL del objetivo |
| `{host}` | Alias de `{ip}` o `{url}` |
| `{port}` | Puerto |
| `{time}` | Tiempo en segundos |

**Ejemplo de argumentos:**
```
Layer 4:  -h {ip} -p {port} -t {time}
Layer 7:  -u {url} --time {time} --threads 100
```

---

## Gestión del servicio

### En VPS (systemd)

```bash
# Ver estado
systemctl status node-agent

# Ver logs en vivo
journalctl -u node-agent -f

# Reiniciar
systemctl restart node-agent

# Detener
systemctl stop node-agent

# Iniciar
systemctl start node-agent

# Deshabilitar autostart
systemctl disable node-agent
```

### En Container con Supervisor

```bash
# Ver estado
supervisorctl status agent

# Ver logs en vivo
tail -f /var/log/node-agent.log

# Reiniciar
supervisorctl restart agent

# Detener
supervisorctl stop agent

# Iniciar
supervisorctl start agent
```

### En Container con Crontab (fallback)

```bash
# Ver logs
tail -f /var/log/node-agent.log

# Detener el agente
pkill -f agent.sh

# Iniciar manualmente
nohup bash /opt/node-agent/agent.sh >> /var/log/node-agent.log 2>&1 &
```

---

## Uso con Docker

Si vas a correr el agente dentro de un contenedor Docker, tienes dos opciones:

### Opción A — El installer dentro del container

```dockerfile
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y curl wget sudo
# El installer se ejecutará al hacer docker run con shell interactiva
```

```bash
docker run -it --name mi-nodo ubuntu:22.04 bash
# Dentro del container:
wget https://raw.githubusercontent.com/flaresamp/flare-node/main/install-node.sh
bash install-node.sh
```

### Opción B — Dockerfile con el agente preconfigado

```dockerfile
FROM ubuntu:22.04

ENV MASTER_URL=http://TU_MASTER_IP
ENV AGENT_TOKEN=TU_TOKEN
ENV NODE_NAME=nodo-docker-1

RUN apt-get update && apt-get install -y curl bc bash procps wget

# Instalar agente (modo no interactivo)
RUN wget -q https://raw.githubusercontent.com/flaresamp/flare-node/main/install-node.sh && \
    MASTER_URL=$MASTER_URL AGENT_TOKEN=$AGENT_TOKEN NODE_NAME=$NODE_NAME \
    bash install-node.sh

# Scripts personalizados
COPY scripts/ /opt/node-agent/scripts/

CMD ["/bin/bash", "/opt/node-agent/start.sh"]
```

```bash
docker build -t flare-node .
docker run -d --name nodo-1 --restart unless-stopped flare-node
```

---

## ¿Qué pasa cuando...?

| Situación | Comportamiento |
|-----------|---------------|
| **El master no está disponible** | El nodo reintenta la conexión cada 10s indefinidamente |
| **El nodo se reinicia** | El servicio arranca automáticamente y se re-registra |
| **El master cancela una tarea** | El nodo mata el proceso inmediatamente con SIGTERM/SIGKILL |
| **La tarea supera el tiempo** | El nodo mata el proceso al llegar al límite de tiempo |
| **El script falla (exit code ≠ 0)** | Se reporta como fallido al master, el nodo queda disponible |
| **El nodo pierde internet 35s** | El master lo marca como offline automáticamente |
| **El nodo reconecta** | Se vuelve a marcar online y retoma tareas normalmente |
| **Nuevo nodo con mismo NODE_ID** | Se actualiza la información en vez de crear uno duplicado |

---

## Seguridad

- Toda comunicación usa el header `x-agent-token` para autenticación
- El token se genera como 64 caracteres hexadecimales aleatorios (`openssl rand -hex 32`)
- El archivo `agent.conf` tiene permisos `600` (solo root puede leerlo)
- Se recomienda usar HTTPS en el master para producción (configurable en `MASTER_URL`)
- El agente **no abre ningún puerto** — toda comunicación es saliente

---

## Solución de problemas

### ❌ Error de GPG / repositorio no firmado durante la instalación

**Síntoma:**
```
W: GPG error: https://dl.yarnpkg.com/debian stable InRelease: The following signatures
   couldn't be verified because the public key is not available: NO_PUBKEY 62D54FD4003F6525
E: The repository 'https://dl.yarnpkg.com/debian stable InRelease' is not signed.
```

**Causa:** El entorno (GitHub Codespaces, algunos contenedores LXC o imágenes preconfiguradas) tiene repositorios de terceros como Yarn, GitHub CLI u otros con claves GPG vencidas o inaccesibles. Cuando `apt-get update` los encuentra, falla y bloquea la instalación.

**Solución:** El installer lo maneja automáticamente desde la versión actual — desactiva temporalmente los repos problemáticos antes del update. Si aun así ves el error, puedes corregirlo manualmente antes de ejecutar el installer:

```bash
# Opción 1 — Deshabilitar repos de terceros problemáticos manualmente
sudo mv /etc/apt/sources.list.d/yarn.list /etc/apt/sources.list.d/yarn.list.bak 2>/dev/null || true
sudo mv /etc/apt/sources.list.d/github-cli.list /etc/apt/sources.list.d/github-cli.list.bak 2>/dev/null || true

# Luego vuelve a correr el installer
sudo bash install-node.sh
```

```bash
# Opción 2 — Forzar update ignorando errores de repos
sudo apt-get update --allow-insecure-repositories -qq 2>/dev/null || true
sudo apt-get install -y curl procps bc

# Luego correr el installer
sudo bash install-node.sh
```

```bash
# Opción 3 — Ver exactamente cuáles repos están fallando
sudo apt-get update 2>&1 | grep -E "^E:|^W:" | sort -u
# Para cada repo problemático:
sudo rm /etc/apt/sources.list.d/REPO_PROBLEMÁTICO.list
```

> **Nota:** Los repos desactivados por el installer se renombran a `.bak` — no se eliminan. Puedes restaurarlos después si los necesitas: `mv /etc/apt/sources.list.d/yarn.list.bak /etc/apt/sources.list.d/yarn.list`

---

### El nodo no aparece en el panel

```bash
# 1. Verifica que el agente esté corriendo
systemctl status node-agent

# 2. Revisa los logs
journalctl -u node-agent -n 50

# 3. Prueba la conexión al master manualmente
curl -v http://TU_MASTER_IP/api/nodes

# 4. Verifica el token en agent.conf
cat /opt/node-agent/agent.conf | grep AGENT_TOKEN

# 5. Compara con el token del master
ssh root@TU_MASTER "cat /opt/master/.env"
```

### El agente se conecta pero aparece offline

```bash
# El master marca offline si no recibe heartbeat en 35s
# Verifica que POLL_INTERVAL sea menor a 30s
grep POLL_INTERVAL /opt/node-agent/agent.conf

# Revisa si hay errores de red
journalctl -u node-agent -f
```

### Los scripts no se ejecutan

```bash
# Verifica que el archivo exista en la carpeta correcta
ls -la /opt/node-agent/scripts/

# Verifica permisos de ejecución (para scripts bash/binarios)
chmod +x /opt/node-agent/scripts/mi_script.sh

# Para Python: verifica que esté instalado
python3 --version

# Para Node.js: verifica que esté instalado
node --version
```

### Reinstalar / limpiar el agente

```bash
# Detener y deshabilitar el servicio
systemctl stop node-agent
systemctl disable node-agent

# Eliminar archivos (los scripts en /scripts/ se pierden — haz backup antes)
rm -rf /opt/node-agent
rm -f /etc/systemd/system/node-agent.service
systemctl daemon-reload

# Volver a instalar
bash install-node.sh
```

---

## Relacionado

- **[flare-master](https://github.com/flaresamp/flare-master)** — Panel web de control (instálalo primero)

---

<div align="center">
<sub>Flare Node Agent — parte del sistema Flare de administración distribuida de servidores</sub>
</div>
