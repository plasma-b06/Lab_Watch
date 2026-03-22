#!/usr/bin/env bash
# ============================================================
#  PC Lab Watch — Agent v3.0
#  Runs on each monitored PC (cron / systemd timer)
#  Produces NO terminal output — silently writes to:
#    1) Shared SQLite DB on NFS/SMB mount  (primary)
#    2) HTTP POST to Flask server          (fallback)
#  Requires: bash 4+, sqlite3, root recommended
# ============================================================

set -euo pipefail

# ── Config — edit these ──────────────────────────────────────
# Mount point of the shared NFS/SMB folder containing lab_watch.db
SHARED_MOUNT="${SHARED_MOUNT:-/mnt/labwatch}"

# Full path to the shared SQLite DB (on the mounted share)
DB_PATH="${DB_PATH:-${SHARED_MOUNT}/lab_watch.db}"

# Flask server fallback (used if SQLite mount is unavailable)
CENTRAL_URL="${CENTRAL_URL:-http://192.168.1.100:5000/api/report}"

# How to reach the server for fallback (curl or wget)
HTTP_TIMEOUT=8

# ── Internal ─────────────────────────────────────────────────
HOSTNAME_LABEL="$(hostname -s 2>/dev/null || echo 'unknown')"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOGFILE="/var/log/lab_watch_agent.log"
TMPJSON="/tmp/lab_watch_$$.json"

log()  { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO]  $*" >> "$LOGFILE" 2>/dev/null || true; }
warn() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [WARN]  $*" >> "$LOGFILE" 2>/dev/null || true; }
err()  { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [ERR]   $*" >> "$LOGFILE" 2>/dev/null || true; }

cleanup() { rm -f "$TMPJSON"; }
trap cleanup EXIT

# ── Thresholds ───────────────────────────────────────────────
CPU_TEMP_WARN=70; CPU_TEMP_CRIT=90; CPU_LOAD_WARN=85
DISK_USAGE_WARN=85; DISK_TEMP_WARN=50; RAM_USAGE_WARN=90

# ── Helpers ──────────────────────────────────────────────────
read_file() { cat "$1" 2>/dev/null || true; }
jstr()      { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; echo "\"$s\""; }
jbool()     { [[ "${1:-0}" == "true" || "${1:-0}" == "1" ]] && echo "true" || echo "false"; }

# ── CPU ──────────────────────────────────────────────────────
collect_cpu() {
  local model cores threads arch freq_mhz load1 load5 load15 cpu_pct
  local status="OK" issues=()

  model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//' || echo "Unknown")
  threads=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
  cores=$(grep -c 'physical id' /proc/cpuinfo 2>/dev/null || echo 0)
  [[ "$cores" -eq 0 ]] && cores=$threads
  arch=$(uname -m 2>/dev/null || echo "unknown")
  freq_mhz=$(grep -m1 'cpu MHz' /proc/cpuinfo 2>/dev/null | awk '{printf "%.0f",$NF}' || echo 0)

  read load1 load5 load15 _ < /proc/loadavg
  local _t="${threads:-1}"; (( _t < 1 )) && _t=1
  cpu_pct=$(awk -v l="$load1" -v t="$_t" 'BEGIN{v=l*100/t; printf "%.1f", v>100?100:v}')

  local temp_max=0 temp_str="null" found_temp=0
  for f in /sys/class/hwmon/hwmon*/temp*_input; do
    [[ -f "$f" ]] || continue
    local raw; raw=$(read_file "$f" | tr -d '\n')
    [[ "$raw" =~ ^[0-9]+$ ]] || continue
    local t=$(( raw / 1000 ))
    (( t > temp_max )) && temp_max=$t && found_temp=1
  done
  if [[ $found_temp -eq 0 ]]; then
    for f in /sys/class/thermal/thermal_zone*/temp; do
      [[ -f "$f" ]] || continue
      local raw; raw=$(read_file "$f" | tr -d '\n')
      [[ "$raw" =~ ^[0-9]+$ ]] || continue
      local t=$(( raw / 1000 ))
      (( t > 10 && t < 120 )) || continue
      (( t > temp_max )) && temp_max=$t && found_temp=1
    done
  fi
  [[ $found_temp -eq 1 ]] && temp_str="$temp_max"

  [[ "$model" == "Unknown" ]] && { issues+=("CPU model unreadable"); status="DEGRADED"; }
  awk -v p="${cpu_pct:-0}" -v w="$CPU_LOAD_WARN" 'BEGIN{exit !(p>=w)}' && {
    issues+=("High CPU load: ${cpu_pct}%"); [[ "$status" == "OK" ]] && status="DEGRADED"; }
  [[ "$temp_str" != "null" ]] && {
    (( temp_max >= CPU_TEMP_CRIT )) && { issues+=("CPU critical temp: ${temp_max}C"); status="NOT_USABLE"; }
    (( temp_max >= CPU_TEMP_WARN && temp_max < CPU_TEMP_CRIT )) && {
      issues+=("CPU high temp: ${temp_max}C"); [[ "$status" == "OK" ]] && status="DEGRADED"; }
  }

  local ij; ij=$(printf ',"%s"' "${issues[@]+"${issues[@]}"}"); ij="[${ij#,}]"
  printf '"cpu":{"model":%s,"arch":%s,"cores":%s,"threads":%s,"freq_mhz":%s,"load1":%s,"load5":%s,"load15":%s,"cpu_pct":%s,"temp_c":%s,"status":%s,"issues":%s}' \
    "$(jstr "$model")" "$(jstr "$arch")" "$cores" "$threads" "$freq_mhz" \
    "$load1" "$load5" "$load15" "$cpu_pct" "$temp_str" "$(jstr "$status")" "$ij"
}

# ── RAM ──────────────────────────────────────────────────────
collect_ram() {
  local total_kb avail_kb used_kb swap_total_kb swap_free_kb used_pct
  local status="OK" issues=()

  total_kb=$(    awk '/^MemTotal:/     {print $2}' /proc/meminfo || echo 1)
  avail_kb=$(    awk '/^MemAvailable:/ {print $2}' /proc/meminfo || echo 0)
  swap_total_kb=$(awk '/^SwapTotal:/   {print $2}' /proc/meminfo || echo 0)
  swap_free_kb=$( awk '/^SwapFree:/    {print $2}' /proc/meminfo || echo 0)
  used_kb=$(( ${total_kb:-0} - ${avail_kb:-0} ))
  local _tkb="${total_kb:-1}"; (( _tkb < 1 )) && _tkb=1
  used_pct=$(awk -v u="${used_kb:-0}" -v t="$_tkb" 'BEGIN{printf "%.1f", u*100/t}')

  local total_gb; total_gb=$(awk -v v="${total_kb:-0}" 'BEGIN{printf "%.2f",v/1048576}')
  local avail_gb; avail_gb=$(awk -v v="${avail_kb:-0}" 'BEGIN{printf "%.2f",v/1048576}')
  local swap_gb;  swap_gb=$( awk -v v="${swap_total_kb:-0}" 'BEGIN{printf "%.2f",v/1048576}')

  (( ${total_kb:-0} < 1024 )) && { issues+=("No RAM detected"); status="NOT_USABLE"; }
  awk -v p="${used_pct:-0}" -v w="$RAM_USAGE_WARN" 'BEGIN{exit !(p>=w)}' && {
    issues+=("High RAM usage: ${used_pct}%"); [[ "$status" == "OK" ]] && status="DEGRADED"; }

  local ij; ij=$(printf ',"%s"' "${issues[@]+"${issues[@]}"}"); ij="[${ij#,}]"
  printf '"ram":{"total_gb":%s,"avail_gb":%s,"used_pct":%s,"swap_gb":%s,"status":%s,"issues":%s}' \
    "$total_gb" "$avail_gb" "$used_pct" "$swap_gb" "$(jstr "$status")" "$ij"
}

# ── Storage ──────────────────────────────────────────────────
collect_storage() {
  local status="OK" issues=() disks=()

  local devs=()
  while IFS= read -r line; do
    [[ "$line" =~ ^(loop|ram|zram|dm-) ]] && continue
    [[ -b "/dev/$line" ]] || continue
    devs+=("$line")
  done < <(ls /sys/block/ 2>/dev/null)

  [[ ${#devs[@]} -eq 0 ]] && { issues+=("No block devices"); status="NOT_USABLE"; }

  for dname in "${devs[@]}"; do
    local size_bytes=0 rotational="null" smart_ok="null" disk_temp="null"
    local health="UNKNOWN" disk_issues=()

    local sz_f="/sys/block/${dname}/size"
    [[ -f "$sz_f" ]] && size_bytes=$(( $(read_file "$sz_f" | tr -d '\n') * 512 ))
    local size_gb; size_gb=$(awk -v b="${size_bytes:-0}" 'BEGIN{printf "%.1f",b/1073741824}')

    local rot_f="/sys/block/${dname}/queue/rotational"
    [[ -f "$rot_f" ]] && rotational=$(read_file "$rot_f" | tr -d '\n')

    if [[ $EUID -eq 0 ]] && command -v smartctl &>/dev/null; then
      local sout; sout=$(smartctl -H "/dev/$dname" 2>/dev/null || true)
      if echo "$sout" | grep -q 'PASSED\|OK'; then smart_ok="true"; health="HEALTHY"
      elif echo "$sout" | grep -q 'FAILED'; then
        smart_ok="false"; health="FAILING"
        disk_issues+=("SMART FAILED"); status="NOT_USABLE"
      fi
      local dt; dt=$(smartctl -A "/dev/$dname" 2>/dev/null | \
        awk '/Temperature_Celsius|Airflow_Temperature/{print $10; exit}' || true)
      [[ "$dt" =~ ^[0-9]+$ ]] && disk_temp=$dt
      [[ "$disk_temp" != "null" ]] && (( disk_temp >= DISK_TEMP_WARN )) && {
        disk_issues+=("High disk temp: ${disk_temp}C"); [[ "$status" == "OK" ]] && status="DEGRADED"; }
    fi

    local fs_usages=()
    while IFS=' ' read -r mdev mpoint _; do
      [[ "$mdev" == "/dev/$dname" || "$mdev" == "/dev/${dname}1" || \
         "$mdev" == "/dev/${dname}p1" ]] || continue
      local dfout; dfout=$(df -k "$mpoint" 2>/dev/null | tail -1) || continue
      local total_k used_k avail_k use_pct
      read -r _ total_k used_k avail_k use_pct _ <<< "$dfout"
      use_pct="${use_pct//%/}"
      local tgb; tgb=$(awk -v k="${total_k:-0}" 'BEGIN{printf "%.1f",k/1048576}')
      fs_usages+=("{\"mount\":$(jstr "$mpoint"),\"total_gb\":$tgb,\"used_pct\":${use_pct:-0}}")
      (( ${use_pct:-0} >= DISK_USAGE_WARN )) && {
        disk_issues+=("${use_pct}% used on $mpoint"); [[ "$status" == "OK" ]] && status="DEGRADED"; }
    done < /proc/mounts

    local fj; fj=$(printf ',%s' "${fs_usages[@]+"${fs_usages[@]}"}"); fj="[${fj#,}]"
    local dij; dij=$(printf ',"%s"' "${disk_issues[@]+"${disk_issues[@]}"}"); dij="[${dij#,}]"
    disks+=("{\"dev\":$(jstr "$dname"),\"size_gb\":$size_gb,\"rotational\":$rotational,\"smart_ok\":$smart_ok,\"health\":$(jstr "$health"),\"temp_c\":$disk_temp,\"fs\":$fj,\"issues\":$dij}")
  done

  local dj; dj=$(printf ',%s' "${disks[@]+"${disks[@]}"}"); dj="[${dj#,}]"
  local ij; ij=$(printf ',"%s"' "${issues[@]+"${issues[@]}"}"); ij="[${ij#,}]"
  printf '"storage":{"devices":%s,"status":%s,"issues":%s}' "$dj" "$(jstr "$status")" "$ij"
}

# ── GPU ──────────────────────────────────────────────────────
collect_gpu() {
  local gpus=() status="OK"

  if command -v nvidia-smi &>/dev/null; then
    while IFS=',' read -r name temp util mem_total mem_used drv; do
      name=$(echo "$name"|sed 's/^ *//;s/ *$//')
      temp=$(echo "$temp"|tr -d ' '); util=$(echo "$util"|tr -d ' ')
      mem_total=$(echo "$mem_total"|tr -d ' '); mem_used=$(echo "$mem_used"|tr -d ' ')
      [[ "$temp" =~ ^[0-9]+$ ]] && (( temp >= 85 )) && status="DEGRADED"
      gpus+=("{\"vendor\":\"NVIDIA\",\"name\":$(jstr "$name"),\"temp_c\":${temp:-null},\"util_pct\":${util:-null},\"vram_total_mb\":${mem_total:-null},\"vram_used_mb\":${mem_used:-null}}")
    done < <(nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.total,memory.used,driver_version \
             --format=csv,noheader,nounits 2>/dev/null || true)
  fi

  if [[ ${#gpus[@]} -eq 0 ]]; then
    for drm in /sys/class/drm/card*/device/vendor; do
      [[ -f "$drm" ]] || continue
      local vid; vid=$(read_file "$drm" | tr -d '\n ')
      gpus+=("{\"vendor\":$(jstr "$vid"),\"name\":\"DRM GPU\",\"temp_c\":null,\"util_pct\":null}")
      break
    done
  fi

  [[ ${#gpus[@]} -eq 0 ]] && gpus+=('{"vendor":"none","name":"Not detected","temp_c":null,"util_pct":null}')
  local gj; gj=$(printf ',%s' "${gpus[@]}"); gj="[${gj#,}]"
  printf '"gpu":{"devices":%s,"status":%s}' "$gj" "$(jstr "$status")"
}

# ── Network ──────────────────────────────────────────────────
collect_network() {
  local ifaces=() status="OK" issues=() has_active=false

  for iface_dir in /sys/class/net/*/; do
    local iface; iface=$(basename "$iface_dir")
    [[ "$iface" == "lo" ]] && continue
    local state; state=$(read_file "${iface_dir}operstate" | tr -d '\n')
    local mac;   mac=$(  read_file "${iface_dir}address"   | tr -d '\n')
    local speed; speed=$(read_file "${iface_dir}speed"     | tr -d '\n' 2>/dev/null || echo "null")
    [[ "$speed" =~ ^-?[0-9]+$ && "$speed" != "-1" ]] || speed="null"
    local rx; rx=$(read_file "${iface_dir}statistics/rx_bytes" | tr -d '\n' || echo 0)
    local tx; tx=$(read_file "${iface_dir}statistics/tx_bytes" | tr -d '\n' || echo 0)
    local ip="null"
    if command -v ip &>/dev/null; then
      local _ip; _ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2; exit}' || true)
      [[ -n "$_ip" ]] && ip=$(jstr "$_ip")
    fi
    [[ "$state" == "up" ]] && has_active=true
    ifaces+=("{\"iface\":$(jstr "$iface"),\"state\":$(jstr "$state"),\"mac\":$(jstr "$mac"),\"ip\":$ip,\"speed_mbps\":$speed,\"rx_bytes\":${rx:-0},\"tx_bytes\":${tx:-0}}")
  done

  $has_active || { issues+=("No active interface"); status="DEGRADED"; }
  [[ ${#ifaces[@]} -eq 0 ]] && { issues+=("No interfaces found"); status="NOT_USABLE"; }

  local ij; ij=$(printf ',%s' "${ifaces[@]+"${ifaces[@]}"}"); ij="[${ij#,}]"
  local isj; isj=$(printf ',"%s"' "${issues[@]+"${issues[@]}"}"); isj="[${isj#,}]"
  printf '"network":{"interfaces":%s,"status":%s,"issues":%s}' "$ij" "$(jstr "$status")" "$isj"
}

# ── System ───────────────────────────────────────────────────
collect_system() {
  local os kernel uptime_s uptime_h boot_time board bios_v bios_vend
  os=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}" || uname -o)
  kernel=$(uname -r)
  read uptime_s _ < /proc/uptime
  uptime_h=$(awk -v s="${uptime_s:-0}" 'BEGIN{printf "%.1f",s/3600}')
  local _be; _be=$(awk -v now="$(date +%s)" -v s="${uptime_s:-0}" 'BEGIN{print int(now-s)}')
  boot_time=$(date -d "@${_be}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
  board=$(    read_file /sys/class/dmi/id/board_name   | tr -d '\n' || echo "unknown")
  bios_vend=$(read_file /sys/class/dmi/id/bios_vendor  | tr -d '\n' || echo "unknown")
  bios_v=$(   read_file /sys/class/dmi/id/bios_version | tr -d '\n' || echo "unknown")
  printf '"system":{"os":%s,"kernel":%s,"uptime_h":%s,"boot_time":%s,"board":%s,"bios":%s,"root":%s}' \
    "$(jstr "$os")" "$(jstr "$kernel")" "$uptime_h" "$(jstr "$boot_time")" \
    "$(jstr "$board")" "$(jstr "$bios_vend $bios_v")" "$(jbool "$([[ $EUID -eq 0 ]] && echo true || echo false)")"
}

# ── Usability ────────────────────────────────────────────────
determine_usability() {
  local cpu_s="$1" ram_s="$2" stor_s="$3" net_s="$4" score=0
  [[ "$cpu_s"  == "NOT_USABLE" ]] && (( score+=10 ))
  [[ "$ram_s"  == "NOT_USABLE" ]] && (( score+=10 ))
  [[ "$stor_s" == "NOT_USABLE" ]] && (( score+=10 ))
  [[ "$cpu_s"  == "DEGRADED"   ]] && (( score+=2  ))
  [[ "$ram_s"  == "DEGRADED"   ]] && (( score+=2  ))
  [[ "$stor_s" == "DEGRADED"   ]] && (( score+=2  ))
  [[ "$net_s"  == "DEGRADED"   ]] && (( score+=1  ))
  [[ "$net_s"  == "NOT_USABLE" ]] && (( score+=3  ))
  (( score >= 10 )) && echo "NOT_USABLE" && return
  (( score >= 2  )) && echo "DEGRADED"   && return
  echo "FULLY_USABLE"
}

# ── Assemble JSON ────────────────────────────────────────────
build_json() {
  local cpu_json ram_json stor_json gpu_json net_json sys_json
  cpu_json=$(collect_cpu)
  ram_json=$(collect_ram)
  stor_json=$(collect_storage)
  gpu_json=$(collect_gpu)
  net_json=$(collect_network)
  sys_json=$(collect_system)

  local cpu_s ram_s stor_s net_s
  cpu_s=$( echo "$cpu_json"  | grep -o '"status":"[^"]*"' | head -1 | cut -d: -f2 | tr -d '"')
  ram_s=$( echo "$ram_json"  | grep -o '"status":"[^"]*"' | head -1 | cut -d: -f2 | tr -d '"')
  stor_s=$(echo "$stor_json" | grep -o '"status":"[^"]*"' | head -1 | cut -d: -f2 | tr -d '"')
  net_s=$( echo "$net_json"  | grep -o '"status":"[^"]*"' | head -1 | cut -d: -f2 | tr -d '"')
  local usability; usability=$(determine_usability "$cpu_s" "$ram_s" "$stor_s" "$net_s")

  cat > "$TMPJSON" <<EOF
{"schema":"3.0","hostname":"${HOSTNAME_LABEL}","collected_at":"${TIMESTAMP}","usability":"${usability}",${sys_json},${cpu_json},${ram_json},${stor_json},${gpu_json},${net_json}}
EOF
}

# ── Write to SQLite ──────────────────────────────────────────
write_sqlite() {
  if ! command -v sqlite3 &>/dev/null; then
    warn "sqlite3 not found, skipping DB write"
    return 1
  fi

  # Ensure DB and table exist (safe to run every time)
  sqlite3 "$DB_PATH" <<'SQL' 2>/dev/null
CREATE TABLE IF NOT EXISTS reports (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  hostname    TEXT    NOT NULL,
  collected_at TEXT   NOT NULL,
  usability   TEXT    NOT NULL,
  payload     TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_host_time ON reports(hostname, collected_at);
SQL

  local payload; payload=$(cat "$TMPJSON")
  local hostname usability collected_at
  hostname=$(echo "$payload" | grep -o '"hostname":"[^"]*"' | cut -d: -f2 | tr -d '"')
  usability=$(echo "$payload" | grep -o '"usability":"[^"]*"' | cut -d: -f2 | tr -d '"')
  collected_at=$(echo "$payload" | grep -o '"collected_at":"[^"]*"' | cut -d: -f2- | tr -d '"')

  # Escape single quotes in JSON for SQLite
  local escaped_payload; escaped_payload="${payload//\'/\'\'}"

  sqlite3 "$DB_PATH" \
    "INSERT INTO reports (hostname, collected_at, usability, payload) VALUES ('${hostname}', '${collected_at}', '${usability}', '${escaped_payload}');" \
    2>/dev/null && return 0 || return 1
}

# ── HTTP fallback ─────────────────────────────────────────────
write_http() {
  [[ -z "$CENTRAL_URL" ]] && return 1
  if command -v curl &>/dev/null; then
    curl -fsSL --max-time "$HTTP_TIMEOUT" \
      -X POST -H "Content-Type: application/json" \
      -d "@$TMPJSON" "$CENTRAL_URL" &>/dev/null && return 0
  elif command -v wget &>/dev/null; then
    wget -qO- --timeout="$HTTP_TIMEOUT" \
      --header="Content-Type: application/json" \
      --post-file="$TMPJSON" "$CENTRAL_URL" &>/dev/null && return 0
  fi
  return 1
}

# ── Main ──────────────────────────────────────────────────────
main() {
  log "Starting collection on $HOSTNAME_LABEL"

  build_json
  log "JSON built ($(wc -c < "$TMPJSON") bytes)"

  # Try shared SQLite first
  if mountpoint -q "$SHARED_MOUNT" 2>/dev/null || [[ -d "$SHARED_MOUNT" ]]; then
    if write_sqlite; then
      log "Written to SQLite: $DB_PATH"
      exit 0
    else
      warn "SQLite write failed, falling back to HTTP"
    fi
  else
    warn "Mount $SHARED_MOUNT not available, falling back to HTTP"
  fi

  # Fallback: HTTP POST
  if write_http; then
    log "Sent via HTTP to $CENTRAL_URL"
    exit 0
  fi

  err "All delivery methods failed for $HOSTNAME_LABEL"
  exit 1
}

main "$@"
