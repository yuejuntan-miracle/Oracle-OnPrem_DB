#!/usr/bin/env bash
# =============================================================================
#  install-oracle-26ai.sh
#
#  Unattended installer for Ubuntu (22.04 / 24.04, x86_64 or aarch64):
#
#    * Oracle AI Database 26ai Free   (official container image, run by Docker)
#    * Oracle APEX 26.2               (installed into the FREEPDB1 PDB)
#    * Oracle REST Data Services 26   (native Java service run by systemd)
#    * Network ACL patch so APEX can call a local vLLM server
#      (OpenAI-compatible API on http://localhost:8000 by default)
#
#  Everything is meant for a single local machine (localhost).
#
#  Oracle only ships the 26ai Free database as an RPM for Oracle Linux/RHEL.
#  On Ubuntu, Oracle's supported route is the container image, so this script
#  runs the database in Docker. ORDS runs on the host and serves APEX.
#
#  Usage:
#     sudo ./install-oracle-26ai.sh                 # install / re-run safely
#     sudo ./install-oracle-26ai.sh --status        # show component status
#     sudo ./install-oracle-26ai.sh --patch-network # re-apply vLLM ACL + test only
#     sudo ./install-oracle-26ai.sh --uninstall     # remove everything (asks)
#     sudo ./install-oracle-26ai.sh --uninstall --yes
#
#  Every setting can be overridden with an environment variable, e.g.
#     sudo ORDS_HTTP_PORT=8181 EXPOSE_DB_PORT=yes ./install-oracle-26ai.sh
#  or saved in /etc/oracle-26ai/install.conf (sourced if present).
#
#  You can run it again safely: each step checks what is already done.
# =============================================================================
set -Eeuo pipefail
umask 022

# ----------------------------------------------------------------------------
# Configuration (override via env or /etc/oracle-26ai/install.conf)
# ----------------------------------------------------------------------------
CONF_DIR="/etc/oracle-26ai"
[[ -f "${CONF_DIR}/install.conf" ]] && source "${CONF_DIR}/install.conf"

# --- Database (container) ---
DB_IMAGE="${DB_IMAGE:-container-registry.oracle.com/database/free:latest}"
DB_CONTAINER="${DB_CONTAINER:-oracle26ai}"
DB_PDB="${DB_PDB:-FREEPDB1}"
DB_CHARSET="${DB_CHARSET:-AL32UTF8}"
DB_PORT="${DB_PORT:-1521}"
EXPOSE_DB_PORT="${EXPOSE_DB_PORT:-no}"          # yes = open 1521 in ufw (bridge mode: bind 0.0.0.0)
# host   = container shares the host network, so "localhost" inside the DB is
#          this machine (needed to reach a vLLM bound to 127.0.0.1). Default.
# bridge = isolated Docker network; the host is reachable as
#          host.docker.internal and vLLM must listen on 0.0.0.0.
DB_NETWORK="${DB_NETWORK:-host}"
if [[ "$DB_NETWORK" == "host" ]]; then DB_PORT=1521; fi   # listener port is fixed in host mode
ORACLE_BASE_DIR="${ORACLE_BASE_DIR:-/opt/oracle}"
ORADATA_DIR="${ORADATA_DIR:-${ORACLE_BASE_DIR}/oradata}"
STAGE_DIR="${STAGE_DIR:-${ORACLE_BASE_DIR}/stage}" # mounted into container
DB_READY_TIMEOUT="${DB_READY_TIMEOUT:-2400}"     # seconds (first start is slow)

# --- APEX ---
APEX_VERSION="${APEX_VERSION:-26.2}"
APEX_URL="${APEX_URL:-https://download.oracle.com/otn_software/apex/apex_${APEX_VERSION}.zip}"
APEX_FALLBACK_URL="${APEX_FALLBACK_URL:-https://download.oracle.com/otn_software/apex/apex-latest.zip}"
APEX_IMAGES_DIR="${APEX_IMAGES_DIR:-${ORACLE_BASE_DIR}/apex/images}"
APEX_ADMIN_EMAIL="${APEX_ADMIN_EMAIL:-admin@localhost}"

# --- ORDS ---
ORDS_MAJOR="${ORDS_MAJOR:-26}"                   # expected major version
ORDS_URL="${ORDS_URL:-https://download.oracle.com/otn_software/java/ords/ords-latest.zip}"
ORDS_HOME="${ORDS_HOME:-${ORACLE_BASE_DIR}/ords}"
ORDS_CONFIG="${ORDS_CONFIG:-/etc/ords/config}"
ORDS_LOG_DIR="${ORDS_LOG_DIR:-/var/log/ords}"
ORDS_HTTP_PORT="${ORDS_HTTP_PORT:-8080}"
ORDS_USER="${ORDS_USER:-ords}"
ORDS_JAVA_MEM="${ORDS_JAVA_MEM:-1024m}"

# --- Local vLLM access from APEX (ORA-24247 network ACL patch) ---
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_HOSTS="${VLLM_HOSTS:-localhost 127.0.0.1}"   # bridge mode adds host.docker.internal
VLLM_TEST_PATH="${VLLM_TEST_PATH:-/v1/models}"
VLLM_API_KEY="${VLLM_API_KEY:-}"                  # only if vLLM runs with --api-key
ACL_EXTRA_SCHEMAS="${ACL_EXTRA_SCHEMAS:-}"        # e.g. "MYAPP" if that schema calls UTL_HTTP itself
APEX_ACL_ALL_HOSTS="${APEX_ACL_ALL_HOSTS:-yes}"   # also allow APEX to reach any host (mail, web services)

# --- Behaviour ---
OPEN_FIREWALL="${OPEN_FIREWALL:-yes}"            # open ORDS port in ufw if active
STRICT_VERSIONS="${STRICT_VERSIONS:-no}"         # yes = fail on version mismatch
CRED_FILE="${CONF_DIR}/credentials.env"
STATE_DIR="/var/lib/oracle-26ai-installer"
LOG_FILE="/var/log/oracle-26ai-install.log"

# Passwords: taken from env, else from a previous run, else generated.
ORACLE_PWD="${ORACLE_PWD:-}"
APEX_ADMIN_PWD="${APEX_ADMIN_PWD:-}"
ORDS_PUBLIC_PWD="${ORDS_PUBLIC_PWD:-}"
APEX_PUBLIC_PWD="${APEX_PUBLIC_PWD:-}"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
C_RESET=$'\e[0m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BLUE=$'\e[34m'
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo "${C_BLUE}[$(ts)]${C_RESET} $*"; }
ok()   { echo "${C_GREEN}[$(ts)] OK${C_RESET}  $*"; }
warn() { echo "${C_YELLOW}[$(ts)] WARN${C_RESET} $*" >&2; }
die()  { echo "${C_RED}[$(ts)] ERROR${C_RESET} $*" >&2; exit 1; }
step() { echo; echo "${C_GREEN}==== $* ====${C_RESET}"; }

on_error() {
  local rc=$? line=${1:-?}
  echo "${C_RED}[$(ts)] FAILED (exit ${rc}) at line ${line}: ${BASH_COMMAND}${C_RESET}" >&2
  echo "See ${LOG_FILE} for the full log. Re-running the script resumes where it stopped." >&2
  exit "$rc"
}
trap 'on_error $LINENO' ERR

done_mark() { mkdir -p "$STATE_DIR"; echo "${2:-done} $(ts)" > "${STATE_DIR}/$1.done"; }

# Password that Oracle, APEX and the shell all accept: starts with a letter,
# contains upper/lower/digit, only letters, digits, '_' and '#'.
gen_pwd() {
  local core
  core="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-14)"
  echo "${1:-Ora}${core}${2:-9}"
}

download() {  # url dest
  local url=$1 dest=$2
  log "Downloading ${url}"
  curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 -o "${dest}.part" "$url"
  mv -f "${dest}.part" "$dest"
}

# Run SQL*Plus as SYSDBA inside the container. SQL comes from stdin.
# Usage: sqlplus_sysdba [workdir-in-container] <<'SQL' ... SQL
sqlplus_sysdba() {
  local wd=${1:-/home/oracle}
  docker exec -i -w "$wd" "$DB_CONTAINER" sqlplus -s -L / as sysdba
}

# Run a single query in the PDB and print the trimmed result.
sql_value() {
  sqlplus_sysdba <<SQL | sed '/^\s*$/d' | tail -n1 | xargs
set heading off feedback off pagesize 0 verify off echo off termout on
whenever sqlerror exit 1
alter session set container=${DB_PDB};
$1
exit
SQL
}

container_exists()  { docker inspect "$DB_CONTAINER" >/dev/null 2>&1; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null)" == "true" ]]; }

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------
preflight() {
  step "Preflight checks"
  [[ $EUID -eq 0 ]] || die "Run as root (sudo)."
  [[ -r /etc/os-release ]] || die "Cannot detect OS."
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || warn "This script targets Ubuntu; detected '${ID:-unknown}'. Continuing."
  case "${VERSION_ID:-}" in 22.04|24.04|24.10|25.04|25.10|26.04) ;; *) warn "Untested Ubuntu version ${VERSION_ID:-?}";; esac

  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) die "Unsupported architecture $(uname -m). Need x86_64 or aarch64." ;;
  esac

  local mem_kb disk_gb
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  (( mem_kb >= 3500000 )) || warn "Less than ~4 GB RAM detected ($((mem_kb/1024)) MB). DB + ORDS may struggle."
  mkdir -p "$ORACLE_BASE_DIR"
  disk_gb=$(df -BG --output=avail "$ORACLE_BASE_DIR" | tail -1 | tr -dc '0-9')
  (( disk_gb >= 20 )) || die "Need at least 20 GB free under ${ORACLE_BASE_DIR} (have ${disk_gb} GB)."
  ok "OS ${PRETTY_NAME:-?}, $(uname -m), RAM $((mem_kb/1024)) MB, free disk ${disk_gb} GB"
}

load_or_create_credentials() {
  step "Credentials"
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
  if [[ -f "$CRED_FILE" ]]; then
    # shellcheck disable=SC1090
    local o=$ORACLE_PWD a=$APEX_ADMIN_PWD p=$ORDS_PUBLIC_PWD q=$APEX_PUBLIC_PWD
    source "$CRED_FILE"
    # values passed explicitly via the environment take precedence
    [[ -n "$o" ]] && ORACLE_PWD=$o
    [[ -n "$a" ]] && APEX_ADMIN_PWD=$a
    [[ -n "$p" ]] && ORDS_PUBLIC_PWD=$p
    [[ -n "$q" ]] && APEX_PUBLIC_PWD=$q
    log "Loaded saved credentials from ${CRED_FILE}"
  fi
  [[ -n "$ORACLE_PWD"      ]] || ORACLE_PWD="$(gen_pwd Ora 9)"
  [[ -n "$APEX_ADMIN_PWD"  ]] || APEX_ADMIN_PWD="$(gen_pwd Apx '#9')"
  [[ -n "$ORDS_PUBLIC_PWD" ]] || ORDS_PUBLIC_PWD="$(gen_pwd Ords 9)"
  [[ -n "$APEX_PUBLIC_PWD" ]] || APEX_PUBLIC_PWD="$(gen_pwd Pub 9)"

  for v in ORACLE_PWD APEX_ADMIN_PWD ORDS_PUBLIC_PWD APEX_PUBLIC_PWD; do
    [[ "${!v}" =~ ^[A-Za-z][A-Za-z0-9_#]{7,29}$ ]] \
      || die "$v must be 8-30 chars, start with a letter, and use only letters, digits, _ or #."
  done

  ( umask 077
    cat > "$CRED_FILE" <<EOF
# Generated by install-oracle-26ai.sh on $(ts). Keep this file secret.
ORACLE_PWD='${ORACLE_PWD}'          # SYS, SYSTEM, PDBADMIN
APEX_ADMIN_PWD='${APEX_ADMIN_PWD}'  # APEX instance admin (workspace INTERNAL, user ADMIN)
ORDS_PUBLIC_PWD='${ORDS_PUBLIC_PWD}'
APEX_PUBLIC_PWD='${APEX_PUBLIC_PWD}'
EOF
  )
  ok "Credentials stored in ${CRED_FILE} (mode 600)"
}

install_packages() {
  step "Installing OS packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl unzip openssl jq rsync procps iproute2 netcat-openbsd

  # Java for ORDS (17 or 21 are supported; prefer 21)
  if ! command -v java >/dev/null 2>&1 || ! java -version 2>&1 | grep -Eq 'version "(17|21|2[2-9])'; then
    apt-get install -y --no-install-recommends openjdk-21-jre-headless \
      || apt-get install -y --no-install-recommends openjdk-17-jre-headless
  fi
  ok "Java: $(java -version 2>&1 | head -1)"

  # Docker
  if ! command -v docker >/dev/null 2>&1; then
    log "Docker not found, installing docker.io from the Ubuntu repositories"
    apt-get install -y docker.io
  fi
  systemctl enable --now docker
  docker info >/dev/null 2>&1 || die "Docker is installed but not running."
  ok "Docker: $(docker --version)"
}

start_database() {
  step "Oracle AI Database 26ai Free (container)"
  mkdir -p "$ORADATA_DIR" "$STAGE_DIR"
  # uid/gid 54321 = 'oracle' inside the image
  chown -R 54321:54321 "$ORADATA_DIR" "$STAGE_DIR"

  if container_exists; then
    local cur_net
    cur_net=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$DB_CONTAINER")
    if [[ ( "$DB_NETWORK" == "host" && "$cur_net" != "host" ) || ( "$DB_NETWORK" != "host" && "$cur_net" == "host" ) ]]; then
      log "Container network is '${cur_net}', wanted '${DB_NETWORK}': re-creating it (data in ${ORADATA_DIR} is kept)"
      docker rm -f "$DB_CONTAINER" >/dev/null
    fi
  fi

  if container_exists; then
    if container_running; then
      log "Container ${DB_CONTAINER} already running"
    else
      log "Starting existing container ${DB_CONTAINER}"
      docker start "$DB_CONTAINER" >/dev/null
    fi
  else
    docker image inspect "$DB_IMAGE" >/dev/null 2>&1 || {
      log "Pulling ${DB_IMAGE} (several GB, may take a while)"
      docker pull "$DB_IMAGE"
    }
    local net_args=()
    if [[ "$DB_NETWORK" == "host" ]]; then
      if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '[:.]1521$'; then
        die "Port 1521 is already in use on this host; free it or use DB_NETWORK=bridge with another DB_PORT."
      fi
      # Oracle's netca needs the container hostname to resolve to a real,
      # non-loopback IPv4 address. In host mode Docker maps it to an IPv6
      # link-local address, which fails ("No valid IP Address returned for
      # the host"). So give the container its own /etc/hosts that maps the
      # hostname to the docker0 bridge IP (stable, local, not loopback).
      local hip
      hip=$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
      [[ -n "$hip" ]] || hip=$(ip -4 -o route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || true)
      [[ -n "$hip" ]] || die "Could not determine a host IPv4 address for the container hostname."
      printf '127.0.0.1\tlocalhost\n::1\tlocalhost ip6-localhost ip6-loopback\n%s\t%s\n' \
        "$hip" "$DB_CONTAINER" > "${ORACLE_BASE_DIR}/container-hosts"
      chmod 644 "${ORACLE_BASE_DIR}/container-hosts"
      log "Container hostname ${DB_CONTAINER} -> ${hip}"
      net_args=(--network host --hostname "$DB_CONTAINER"
                -v "${ORACLE_BASE_DIR}/container-hosts:/etc/hosts:ro")
    else
      local bind="127.0.0.1:"
      [[ "$EXPOSE_DB_PORT" == "yes" ]] && bind=""
      net_args=(--hostname "$DB_CONTAINER" -p "${bind}${DB_PORT}:1521"
                --add-host=host.docker.internal:host-gateway)
    fi
    log "Creating container ${DB_CONTAINER} (network: ${DB_NETWORK})"
    docker run -d \
      --name "$DB_CONTAINER" \
      --restart unless-stopped \
      "${net_args[@]}" \
      -e ORACLE_PWD="$ORACLE_PWD" \
      -e ORACLE_CHARACTERSET="$DB_CHARSET" \
      -v "${ORADATA_DIR}:/opt/oracle/oradata" \
      -v "${STAGE_DIR}:/opt/oracle/stage" \
      "$DB_IMAGE" >/dev/null
  fi

  log "Waiting for the database to become healthy (timeout ${DB_READY_TIMEOUT}s)..."
  local waited=0 status
  while :; do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$DB_CONTAINER" 2>/dev/null || echo missing)
    [[ "$status" == "healthy" ]] && break
    if [[ "$status" == "none" ]] && docker logs "$DB_CONTAINER" 2>&1 | grep -q 'DATABASE IS READY TO USE'; then
      break
    fi
    container_running || { docker logs --tail 50 "$DB_CONTAINER" >&2; die "Container stopped unexpectedly."; }
    if (( $(docker inspect -f '{{.RestartCount}}' "$DB_CONTAINER" 2>/dev/null || echo 0) >= 2 )); then
      docker logs --tail 50 "$DB_CONTAINER" >&2
      die "Database container is in a restart loop (see logs above)."
    fi
    (( waited >= DB_READY_TIMEOUT )) && { docker logs --tail 50 "$DB_CONTAINER" >&2; die "Database not ready after ${DB_READY_TIMEOUT}s."; }
    sleep 15; waited=$((waited + 15))
    (( waited % 120 == 0 )) && log "  ...still waiting (${waited}s, health=${status})"
  done

  # Make sure the PDB is open and stays open across restarts
  sqlplus_sysdba <<SQL >/dev/null
whenever sqlerror exit 1
declare
  l_mode v\$pdbs.open_mode%type;
begin
  select open_mode into l_mode from v\$pdbs where name = upper('${DB_PDB}');
  if l_mode <> 'READ WRITE' then
    execute immediate 'alter pluggable database ${DB_PDB} open read write';
  end if;
  execute immediate 'alter pluggable database ${DB_PDB} save state';
end;
/
exit
SQL
  [[ "$(sql_value "select open_mode from v\$pdbs;")" == "READ WRITE" ]] \
    || die "PDB ${DB_PDB} is not open READ WRITE."

  local banner
  banner=$(sqlplus_sysdba <<'SQL' | sed '/^\s*$/d' | head -1
set heading off feedback off pagesize 0
select banner_full from v$version where rownum = 1;
exit
SQL
)
  ok "Database ready: ${banner}"
  [[ "$banner" == *26ai* ]] || warn "Banner does not mention 26ai; check DB_IMAGE (${DB_IMAGE})."
  done_mark database
}

install_apex() {
  step "Oracle APEX ${APEX_VERSION}"
  local zip="${STAGE_DIR}/apex.zip" zip_sum installed
  if [[ ! -s "$zip" ]] || [[ "$(cat "${STATE_DIR}/apex.url" 2>/dev/null)" != "$APEX_URL" ]]; then
    if ! download "$APEX_URL" "$zip"; then
      warn "APEX ${APEX_VERSION} not found at ${APEX_URL}; falling back to ${APEX_FALLBACK_URL}"
      download "$APEX_FALLBACK_URL" "$zip"
    fi
    mkdir -p "$STATE_DIR"; echo "$APEX_URL" > "${STATE_DIR}/apex.url"
  fi
  zip_sum=$(sha256sum "$zip" | awk '{print $1}')

  installed=$(sql_value "select nvl(max(version),'NONE') from dba_registry where comp_id='APEX' and status='VALID';" || echo NONE)
  log "APEX currently in ${DB_PDB}: ${installed}"

  # Always unpack (needed for images even if the DB part is already there)
  rm -rf "${STAGE_DIR}/apex"
  unzip -q -o "$zip" -d "$STAGE_DIR"
  chown -R 54321:54321 "${STAGE_DIR}/apex"

  if [[ "$installed" != "NONE" ]] && [[ "$(cat "${STATE_DIR}/apex.done" 2>/dev/null | awk '{print $1}')" == "$zip_sum" ]]; then
    log "This APEX package is already installed; skipping apexins.sql"
  elif [[ "$installed" == ${APEX_VERSION}* ]]; then
    log "APEX ${installed} already matches ${APEX_VERSION}; skipping apexins.sql"
  else
    log "Running apexins.sql in ${DB_PDB} (usually 10-30 minutes)..."
    sqlplus_sysdba /opt/oracle/stage/apex <<SQL
whenever sqlerror exit sql.sqlcode
alter session set container=${DB_PDB};
@apexins.sql SYSAUX SYSAUX TEMP /i/
exit
SQL
    installed=$(sql_value "select nvl(max(version),'NONE') from dba_registry where comp_id='APEX' and status='VALID';")
    [[ "$installed" != "NONE" ]] || die "APEX installation did not produce a VALID registry entry. Check logs in ${STAGE_DIR}/apex/*.log"
  fi

  if [[ "$installed" != ${APEX_VERSION}* ]]; then
    if [[ "$STRICT_VERSIONS" == "yes" ]]; then die "Installed APEX ${installed} != requested ${APEX_VERSION}"
    else warn "Installed APEX is ${installed}, requested ${APEX_VERSION} (set APEX_URL to pin a version)"; fi
  fi

  log "Configuring APEX admin, public user and network ACL"
  sqlplus_sysdba <<SQL
whenever sqlerror exit sql.sqlcode
set define off feedback off
alter session set container=${DB_PDB};
set serveroutput on size unlimited

-- APEX_PUBLIC_USER is used by ORDS (proxied gateway mode)
alter user APEX_PUBLIC_USER identified by "${APEX_PUBLIC_PWD}" account unlock;

-- Instance administrator: workspace INTERNAL, user ADMIN
declare
  l_schema varchar2(128);
begin
  select schema into l_schema from dba_registry where comp_id = 'APEX';
  execute immediate 'alter session set current_schema = ' || dbms_assert.enquote_name(l_schema);

  apex_util.set_security_group_id(10);   -- 10 = INTERNAL workspace
  begin
    apex_util.remove_user(p_user_name => 'ADMIN');   -- re-create => idempotent
  exception when others then null;
  end;
  apex_util.create_user(
    p_user_name                    => 'ADMIN',
    p_email_address                => '${APEX_ADMIN_EMAIL}',
    p_web_password                 => '${APEX_ADMIN_PWD}',
    p_developer_privs              => 'ADMIN:CREATE:DATA_LOADER:EDIT:HELP:MONITOR:SQL',
    p_change_password_on_first_use => 'N');
  apex_util.set_security_group_id(null);
  commit;

  -- Optionally allow APEX to reach any host (web services, mail)
  if '${APEX_ACL_ALL_HOSTS}' = 'yes' then
    dbms_network_acl_admin.append_host_ace(
      host => '*',
      ace  => xs\$ace_type(privilege_list => xs\$name_list('connect','resolve'),
                           principal_name => l_schema,
                           principal_type => xs_acl.ptype_db));
    commit;
  end if;
  dbms_output.put_line('APEX schema: ' || l_schema);
end;
/
exit
SQL

  # Static files ORDS serves under /i/
  mkdir -p "$APEX_IMAGES_DIR"
  rsync -a --delete "${STAGE_DIR}/apex/images/" "${APEX_IMAGES_DIR}/"
  echo "$zip_sum $installed" > "${STATE_DIR}/apex.done"
  ok "APEX ${installed} installed in ${DB_PDB}"
}

install_ords() {
  step "Oracle REST Data Services ${ORDS_MAJOR}"
  id -u "$ORDS_USER" >/dev/null 2>&1 \
    || useradd --system --home-dir "$ORDS_HOME" --shell /usr/sbin/nologin "$ORDS_USER"

  local zip="${ORACLE_BASE_DIR}/ords.zip" ver
  if [[ ! -x "${ORDS_HOME}/bin/ords" ]]; then
    download "$ORDS_URL" "$zip"
    rm -rf "$ORDS_HOME"; mkdir -p "$ORDS_HOME"
    unzip -q -o "$zip" -d "$ORDS_HOME"
    rm -f "$zip"
  fi
  ln -sf "${ORDS_HOME}/bin/ords" /usr/local/bin/ords
  ver=$("${ORDS_HOME}/bin/ords" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -1 || true)
  log "ORDS version: ${ver:-unknown}"
  if [[ "${ver%%.*}" != "$ORDS_MAJOR" ]]; then
    if [[ "$STRICT_VERSIONS" == "yes" ]]; then die "ORDS ${ver} is not major version ${ORDS_MAJOR}"
    else warn "ORDS ${ver} is not major version ${ORDS_MAJOR} (set ORDS_URL to pin a version)"; fi
  fi

  mkdir -p "$ORDS_CONFIG" "$ORDS_LOG_DIR"
  chown -R "$ORDS_USER:$ORDS_USER" "$ORDS_CONFIG" "$ORDS_LOG_DIR" "$ORDS_HOME"

  if [[ -f "${ORDS_CONFIG}/databases/default/pool.xml" ]]; then
    log "ORDS already configured in ${ORDS_CONFIG}; skipping 'ords install'"
  else
    log "Installing ORDS into ${DB_PDB} (APEX gateway: proxied via APEX_PUBLIC_USER)"
    # stdin: 1) SYS password  2) ORDS_PUBLIC_USER password
    printf '%s\n%s\n' "$ORACLE_PWD" "$ORDS_PUBLIC_PWD" | \
      runuser -u "$ORDS_USER" -- "${ORDS_HOME}/bin/ords" --config "$ORDS_CONFIG" install \
        --admin-user SYS \
        --db-hostname 127.0.0.1 \
        --db-port "$DB_PORT" \
        --db-servicename "$DB_PDB" \
        --feature-db-api true \
        --feature-rest-enabled-sql true \
        --feature-sdw true \
        --gateway-mode proxied \
        --gateway-user APEX_PUBLIC_USER \
        --proxy-user \
        --log-folder "$ORDS_LOG_DIR" \
        --password-stdin
  fi

  log "Applying ORDS standalone settings"
  local o=(runuser -u "$ORDS_USER" -- "${ORDS_HOME}/bin/ords" --config "$ORDS_CONFIG" config)
  "${o[@]}" set standalone.http.port "$ORDS_HTTP_PORT"   >/dev/null
  "${o[@]}" set standalone.static.context.path /i         >/dev/null
  "${o[@]}" set standalone.static.path "$APEX_IMAGES_DIR" >/dev/null
  "${o[@]}" set jdbc.InitialLimit 5                       >/dev/null
  "${o[@]}" set jdbc.MaxLimit 30                          >/dev/null

  cat > /etc/systemd/system/ords.service <<EOF
[Unit]
Description=Oracle REST Data Services (APEX / REST for Oracle AI Database 26ai Free)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=${ORDS_USER}
Group=${ORDS_USER}
Environment=JAVA_OPTIONS=-Xmx${ORDS_JAVA_MEM}
# Wait (up to 30 min) until the database listener accepts connections
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 360); do nc -z 127.0.0.1 ${DB_PORT} && exit 0; sleep 5; done; exit 1'
ExecStart=${ORDS_HOME}/bin/ords --config ${ORDS_CONFIG} serve
Restart=on-failure
RestartSec=10
TimeoutStartSec=1900
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ords >/dev/null 2>&1
  systemctl restart ords

  log "Waiting for ORDS to answer on port ${ORDS_HTTP_PORT}..."
  local i code=000
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ORDS_HTTP_PORT}/ords/" || true)
    [[ "$code" =~ ^(200|301|302|303)$ ]] && break
    sleep 5
  done
  [[ "$code" =~ ^(200|301|302|303)$ ]] || { journalctl -u ords -n 60 --no-pager >&2; die "ORDS not responding (HTTP ${code})."; }
  ok "ORDS ${ver:-} is serving on port ${ORDS_HTTP_PORT}"
  done_mark ords "$ver"
}

# ----------------------------------------------------------------------------
# Network ACL patch: let APEX (and optional extra schemas) call local vLLM.
# Without it, APEX_WEB_SERVICE / Generative AI calls fail with
#   ORA-24247: network access denied by access control list (ACL)
# ----------------------------------------------------------------------------
patch_network_vllm() {
  step "Network ACL patch for local vLLM (port ${VLLM_PORT})"
  container_running || die "Database container ${DB_CONTAINER} is not running."

  local net hosts
  net=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$DB_CONTAINER")
  hosts="$VLLM_HOSTS"
  if [[ "$net" != "host" && " $hosts " != *" host.docker.internal "* ]]; then
    hosts="$hosts host.docker.internal"
  fi
  log "Container network: ${net}; granting access to: ${hosts}"

  # Principals: APEX engine schema (used by APEX_WEB_SERVICE, Generative AI
  # services, REST data sources) + any extra schemas listed.
  local principals="'APEX'" s host_list="" h
  for s in $ACL_EXTRA_SCHEMAS; do principals="${principals},'${s^^}'"; done
  for h in $hosts; do host_list="${host_list:+${host_list},}'${h}'"; done

  sqlplus_sysdba <<SQL
whenever sqlerror exit sql.sqlcode
set define off feedback off linesize 200
alter session set container=${DB_PDB};
set serveroutput on size unlimited
declare
  type t_list is table of varchar2(255);
  l_hosts      t_list := t_list(${host_list});
  l_principals t_list := t_list(${principals});
  l_user       varchar2(128);
  l_cnt        pls_integer;
begin
  for p in 1 .. l_principals.count loop
    l_user := l_principals(p);
    if l_user = 'APEX' then
      select schema into l_user from dba_registry where comp_id = 'APEX';
    end if;
    select count(*) into l_cnt from dba_users where username = l_user;
    if l_cnt = 0 then
      dbms_output.put_line('WARN: schema ' || l_user || ' does not exist, skipped');
      continue;
    end if;
    for h in 1 .. l_hosts.count loop
      -- connect + http on the vLLM port only
      dbms_network_acl_admin.append_host_ace(
        host       => l_hosts(h),
        lower_port => ${VLLM_PORT},
        upper_port => ${VLLM_PORT},
        ace        => xs\$ace_type(privilege_list => xs\$name_list('connect','http'),
                                  principal_name => l_user,
                                  principal_type => xs_acl.ptype_db));
      -- name resolution (must be granted without a port range)
      dbms_network_acl_admin.append_host_ace(
        host => l_hosts(h),
        ace  => xs\$ace_type(privilege_list => xs\$name_list('resolve'),
                            principal_name => l_user,
                            principal_type => xs_acl.ptype_db));
      dbms_output.put_line('ACL: ' || rpad(l_user, 16) || ' -> ' || l_hosts(h) || ':${VLLM_PORT}');
    end loop;
  end loop;
  commit;
end;
/
exit
SQL
  ok "Network ACL applied"

  # 1) Can the database's network namespace reach vLLM at all?
  local test_host reachable=""
  for test_host in $hosts; do
    if docker exec "$DB_CONTAINER" bash -c "timeout 5 bash -c '</dev/tcp/${test_host}/${VLLM_PORT}'" 2>/dev/null; then
      reachable=$test_host; break
    fi
  done
  if [[ -z "$reachable" ]]; then
    warn "vLLM is not reachable on port ${VLLM_PORT} from the database right now (ACL is in place)."
    warn "Start vLLM (e.g. 'vllm serve <model> --port ${VLLM_PORT}') and re-test: sudo $0 --patch-network"
    if [[ "$net" != "host" ]]; then warn "Bridge mode: vLLM must listen on 0.0.0.0 (--host 0.0.0.0)."; fi
    return 0
  fi
  ok "TCP connection from the database to ${reachable}:${VLLM_PORT} works"

  # 2) Real HTTP call through APEX_WEB_SERVICE (checked against the APEX schema's ACL)
  local url="http://${reachable}:${VLLM_PORT}${VLLM_TEST_PATH}"
  log "Calling ${url} through APEX_WEB_SERVICE..."
  if sqlplus_sysdba <<SQL
whenever sqlerror exit 1
set define off feedback off linesize 200
alter session set container=${DB_PDB};
set serveroutput on size unlimited
declare
  l_schema varchar2(128);
  l_resp   clob;
begin
  select schema into l_schema from dba_registry where comp_id = 'APEX';
  execute immediate 'alter session set current_schema = ' || dbms_assert.enquote_name(l_schema);
  apex_util.set_security_group_id(10);
  apex_web_service.clear_request_headers;
  if '${VLLM_API_KEY}' is not null then
    apex_web_service.set_request_headers('Authorization', 'Bearer ${VLLM_API_KEY}');
  end if;
  l_resp := apex_web_service.make_rest_request(p_url => '${url}', p_http_method => 'GET');
  dbms_output.put_line('HTTP ' || apex_web_service.g_status_code || ': ' || dbms_lob.substr(l_resp, 300, 1));
  if apex_web_service.g_status_code <> 200 then
    raise_application_error(-20001, 'vLLM returned HTTP ' || apex_web_service.g_status_code);
  end if;
end;
/
exit
SQL
  then
    ok "APEX can call vLLM at http://${reachable}:${VLLM_PORT}"
  else
    warn "APEX_WEB_SERVICE test failed (output above). On ORA-24247 re-run: sudo $0 --patch-network"
  fi
}

configure_firewall() {
  [[ "$OPEN_FIREWALL" == "yes" ]] || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
    step "Firewall (ufw)"
    ufw allow "${ORDS_HTTP_PORT}/tcp" >/dev/null && ok "Opened ${ORDS_HTTP_PORT}/tcp"
    if [[ "$EXPOSE_DB_PORT" == "yes" ]]; then
      ufw allow "${DB_PORT}/tcp" >/dev/null && ok "Opened ${DB_PORT}/tcp"
    fi
  fi
}

verify() {
  step "Verification"
  local apex_code
  # APEX redirects to its sign-in page and needs the session cookie to follow
  local jar; jar=$(mktemp)
  apex_code=$(curl -s -o /dev/null -w '%{http_code}' -L -c "$jar" -b "$jar" "http://127.0.0.1:${ORDS_HTTP_PORT}/ords/apex" || true)
  rm -f "$jar"
  [[ "$apex_code" == "200" ]] && ok "APEX login page reachable (HTTP 200)" \
    || warn "APEX page returned HTTP ${apex_code}; check 'journalctl -u ords'"
  curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ORDS_HTTP_PORT}/i/apex_version.js" | grep -q 200 \
    && ok "APEX static files served under /i/" || warn "APEX static files under /i/ not found"
}

summary() {
  local host apex_ver ords_ver
  host=$(hostname -I 2>/dev/null | awk '{print $1}'); host=${host:-localhost}
  apex_ver=$(sql_value "select version from dba_registry where comp_id='APEX';" 2>/dev/null || echo '?')
  ords_ver=$("${ORDS_HOME}/bin/ords" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -1 || echo '?')
  cat <<EOF

${C_GREEN}=====================================================================
  Oracle AI Database 26ai Free + ORDS + APEX: installation complete
=====================================================================${C_RESET}
  Database container : ${DB_CONTAINER}   (image ${DB_IMAGE})
  Connect (PDB)      : sqlplus system/<ORACLE_PWD>@//localhost:${DB_PORT}/${DB_PDB}
  Connect (CDB)      : sqlplus sys/<ORACLE_PWD>@//localhost:${DB_PORT}/FREE as sysdba
  Shell in container : docker exec -it ${DB_CONTAINER} sqlplus / as sysdba

  APEX ${apex_ver}
    URL              : http://${host}:${ORDS_HTTP_PORT}/ords/apex
    Admin services   : http://${host}:${ORDS_HTTP_PORT}/ords/apex_admin
    Workspace / user : INTERNAL / ADMIN
  ORDS ${ords_ver}
    Landing page     : http://${host}:${ORDS_HTTP_PORT}/ords/
    SQL Developer Web: http://${host}:${ORDS_HTTP_PORT}/ords/sql-developer
    Service          : systemctl status ords   (logs: journalctl -u ords)

  Local vLLM from APEX
    Base URL in APEX : http://localhost:${VLLM_PORT}/v1   (DB network: ${DB_NETWORK})
    Gen AI service   : Workspace Utilities > Generative AI > Create
                       Provider "OpenAI", URL above, any API key unless vLLM uses --api-key
    Re-apply / test  : sudo $0 --patch-network

  All passwords      : ${CRED_FILE}   (root only)
  Install log        : ${LOG_FILE}
EOF
  if [[ "$DB_NETWORK" == "host" ]]; then
    echo "  Note: host networking - the DB listener binds all interfaces; keep 1521 closed in your"
    echo "        firewall unless you need remote access (EXPOSE_DB_PORT=yes opens it in ufw)."
  elif [[ "$EXPOSE_DB_PORT" != "yes" ]]; then
    echo "  Note: port ${DB_PORT} only listens on 127.0.0.1 (set EXPOSE_DB_PORT=yes to open it)."
  fi
  echo
}

status() {
  echo "--- Database container ---"
  docker ps -a --filter "name=^${DB_CONTAINER}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || echo "docker not available"
  echo "--- ORDS service ---"
  systemctl --no-pager --lines=0 status ords 2>/dev/null || echo "ords service not installed"
  if container_running; then
    echo "--- Components in ${DB_PDB} ---"
    sqlplus_sysdba <<SQL
set heading on feedback off pagesize 100 linesize 160
col comp_id for a10
col comp_name for a45
col version for a20
col status for a10
alter session set container=${DB_PDB};
select comp_id, comp_name, version, status from dba_registry order by comp_id;
col host for a24
col principal for a16
col privilege for a10
prompt
prompt Network ACEs (host access):
select host, lower_port, upper_port, principal, privilege from dba_host_aces
 where principal not in ('GSMADMIN_INTERNAL','GGSYS') order by host, principal, privilege;
exit
SQL
  fi
}

uninstall() {
  local yes=${1:-}
  [[ $EUID -eq 0 ]] || die "Run as root (sudo)."
  if [[ "$yes" != "--yes" ]]; then
    read -r -p "This deletes the container, ALL database files in ${ORADATA_DIR}, ORDS and APEX. Type 'DELETE' to continue: " ans
    [[ "$ans" == "DELETE" ]] || die "Aborted."
  fi
  systemctl disable --now ords 2>/dev/null || true
  rm -f /etc/systemd/system/ords.service /usr/local/bin/ords; systemctl daemon-reload
  docker rm -f "$DB_CONTAINER" 2>/dev/null || true
  rm -rf "$ORADATA_DIR" "$STAGE_DIR" "$ORDS_HOME" "$(dirname "$APEX_IMAGES_DIR")" \
         "${ORACLE_BASE_DIR}/container-hosts" "${ORACLE_BASE_DIR}/ords.zip" \
         "$(dirname "$ORDS_CONFIG")" "$ORDS_LOG_DIR" "$STATE_DIR" "$CONF_DIR"
  userdel "$ORDS_USER" 2>/dev/null || true
  ok "Uninstalled. The Docker image ${DB_IMAGE} is kept (remove with: docker rmi ${DB_IMAGE})."
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  case "${1:-install}" in
    --status)    status; exit 0 ;;
    --patch-network)
      [[ $EUID -eq 0 ]] || die "Run as root (sudo)."
      patch_network_vllm; exit 0 ;;
    --uninstall) uninstall "${2:-}"; exit 0 ;;
    install|--install) ;;
    -h|--help)   sed -n '2,34p' "$0"; exit 0 ;;
    *) die "Unknown option '$1'. Use --help." ;;
  esac

  [[ $EUID -eq 0 ]] || die "Run as root (sudo)."
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "Starting Oracle AI Database 26ai Free + ORDS + APEX installer"

  preflight
  load_or_create_credentials
  install_packages
  start_database
  install_apex
  install_ords
  patch_network_vllm
  configure_firewall
  verify
  summary
}

main "$@"
