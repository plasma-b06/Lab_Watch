#!/usr/bin/env bash
# ============================================================
#  PC Lab Watch - Hardware Usability & Condition Monitor
#  Version : 2.0
#  Author  : Lab Watch Project
#  Requires: bash 4+, run as root for full SMART/temp access
#  Deps    : NONE beyond standard Linux core-utils + /sys /proc
# ============================================================

set -euo pipefail

# ── Configuration ────────────────────────────────────────────
REPORT_DIR="${REPORT_DIR:-/var/log/lab_watch}"
HOSTNAME_LABEL="$(hostname -s 2>/dev/null || echo 'unknown')"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REPORT_FILE="${REPORT_DIR}/report_${HOSTNAME_LABEL}_$(date +%Y%m%d_%H%M%S).json"

# Thresholds
CPU_TEMP_WARN=70     # °C
CPU_TEMP_CRIT=90     # °C
CPU_LOAD_WARN=85     # %
DISK_USAGE_WARN=85   # %
DISK_TEMP_WARN=50    # °C
RAM_USAGE_WARN=90    # %
SMART_FAIL_ATTR="5 10 196 197 198"   # Reallocated/Pending/Uncorrectable sectors

# Central server (optional – set or leave empty)
CENTRAL_URL="${CENTRAL_URL:-}"

# ── Colour helpers (disabled when piped) ─────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; YLW='\033[0;33m'; GRN='\033[0;32m'
  CYN='\033[0;36m'; BLD='\033[1m';    RST='\033[0m'
else
  RED=''; YLW=''; GRN=''; CYN=''; BLD=''; RST=''
fi

log()  { echo -e "${CYN}[INFO]${RST}  $*"; }
warn() { echo -e "${YLW}[WARN]${RST}  $*"; }
err()  { echo -e "${RED}[ERR]${RST}   $*" >&2; }
ok()   { echo -e "${GRN}[OK]${RST}    $*"; }

# ── Utility: read first matching line from /proc or /sys ──────
read_file() { cat "$1" 2>/dev/null || true; }

# ── JSON helpers ─────────────────────────────────────────────
jstr()  { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; echo "\"$s\""; }
jbool() { [[ "$1" == "true" || "$1" == "1" || "$1" -ne 0 ]] 2>/dev/null && echo "true" || echo "false"; }

# ── 1. CPU ────────────────────────────────────────────────────
collect_cpu() {
  local model cores threads arch freq_mhz bogomips
  local load1 load5 load15 cpu_pct status issues=()

  model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//' || echo "Unknown")
  cores=$(grep -c 'physical id' /proc/cpuinfo 2>/dev/null || echo 0)
  # fallback: count unique core ids
  [[ "$cores" -eq 0 ]] && cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
  threads=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
  arch=$(uname -m 2>/dev/null || echo "unknown")
  freq_mhz=$(grep -m1 'cpu MHz' /proc/cpuinfo 2>/dev/null | awk '{printf "%.0f",$NF}' || echo 0)
  bogomips=$(grep -m1 'bogomips' /proc/cpuinfo 2>/dev/null | awk '{print $NF}' || echo 0)

  # Load average (1-min), derive CPU %
  read load1 load5 load15 _ < /proc/loadavg
  local _t; _t="${threads:-1}"; (( _t < 1 )) && _t=1
  cpu_pct=$(awk -v l="$load1" -v t="$_t" 'BEGIN{v=l*100/t; printf "%.1f", v>100?100:v}')

  # Temperatures via hwmon
  local temps=() temp_max=0 temp_str="null"
  for f in /sys/class/hwmon/hwmon*/temp*_input; do
    [[ -f "$f" ]] || continue
    local label_f="${f%_input}_label"
    local lbl; lbl=$(read_file "$label_f" | tr -d '\n')
    [[ "$lbl" =~ [Cc][Pp][Uu] || "$lbl" =~ [Cc]ore ]] || [[ "$lbl" == "" ]] || continue
    local raw; raw=$(read_file "$f" | tr -d '\n')
    [[ "$raw" =~ ^[0-9]+$ ]] || continue
    local t=$(( raw / 1000 ))
    temps+=("$t")
    (( t > temp_max )) && temp_max=$t
  done
  # Also try /sys/class/thermal
  if [[ ${#temps[@]} -eq 0 ]]; then
    for f in /sys/class/thermal/thermal_zone*/temp; do
      [[ -f "$f" ]] || continue
      local raw; raw=$(read_file "$f" | tr -d '\n')
      [[ "$raw" =~ ^[0-9]+$ ]] || continue
      local t=$(( raw / 1000 ))
      (( t > 10 && t < 120 )) || continue  # sanity
      temps+=("$t")
      (( t > temp_max )) && temp_max=$t
    done
  fi
  [[ ${#temps[@]} -gt 0 ]] && temp_str="$temp_max"

  # Evaluate
  status="OK"
  [[ "$model" == "Unknown" ]] && { issues+=("CPU model unreadable"); status="DEGRADED"; }
  (( threads < 1 ))            && { issues+=("No CPU threads detected"); status="NOT_USABLE"; }
  awk -v p="${cpu_pct:-0}" -v w="$CPU_LOAD_WARN" 'BEGIN{exit !(p >= w)}' && { issues+=("High CPU load: ${cpu_pct}%"); [[ "$status" == "OK" ]] && status="DEGRADED"; }
  [[ "$temp_str" != "null" ]] && {
    (( temp_max >= CPU_TEMP_CRIT )) && { issues+=("CPU critical temperature: ${temp_max}°C"); status="NOT_USABLE"; }
    (( temp_max >= CPU_TEMP_WARN && temp_max < CPU_TEMP_CRIT )) && { issues+=("CPU high temperature: ${temp_max}°C"); [[ "$status" == "OK" ]] && status="DEGRADED"; }
  }

  local issues_json; issues_json=$(printf ',"%s"' "${issues[@]+"${issues[@]}"}"); issues_json="[${issues_json#,}]"
  cat <<EOF
"cpu":{
  "model":$(jstr "$model"),
  "architecture":$(jstr "$arch"),
  "physical_cores":$cores,
  "threads":$threads,
  "freq_mhz":$freq_mhz,
  "bogomips":$bogomips,
  "load_avg":{"1m":$load1,"5m":$load5,"15m":$load15},
  "cpu_utilization_pct":$cpu_pct,
  "temp_celsius":$temp_str,
  "status":$(jstr "$status"),
  "issues":$issues_json
}
EOF
}

# ── 2. RAM ────────────────────────────────────────────────────
collect_ram() {
  local total_kb avail_kb used_kb swap_total_kb swap_free_kb
  local used_pct status issues=()

  total_kb=$(  awk '/^MemTotal:/     {print $2}' /proc/meminfo)
  avail_kb=$(  awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  swap_total_kb=$(awk '/^SwapTotal:/  {print $2}' /proc/meminfo)
  swap_free_kb=$( awk '/^SwapFree:/   {print $2}' /proc/meminfo)

  used_kb=$(( ${total_kb:-0} - ${avail_kb:-0} ))
  local _tkb="${total_kb:-1}"; (( _tkb < 1 )) && _tkb=1
  used_pct=$(awk -v u="${used_kb:-0}" -v t="$_tkb" 'BEGIN{printf "%.1f", u*100/t}')

  local total_gb;     total_gb=$(    awk -v v="${total_kb:-0}"     'BEGIN{printf "%.2f", v/1048576}')
  local avail_gb;     avail_gb=$(    awk -v v="${avail_kb:-0}"     'BEGIN{printf "%.2f", v/1048576}')
  local swap_total_gb; swap_total_gb=$(awk -v v="${swap_total_kb:-0}" 'BEGIN{printf "%.2f", v/1048576}')

  # DIMM slots via dmidecode (optional – needs root)
  local dimm_count="null" dimm_speed="null"
  if command -v dmidecode &>/dev/null && [[ $EUID -eq 0 ]]; then
    dimm_count=$(dmidecode -t 17 2>/dev/null | grep -c 'Speed:.*MHz' || echo "null")
    dimm_speed=$(dmidecode -t 17 2>/dev/null | grep 'Speed:.*MHz' | head -1 | awk '{print $2}' || echo "null")
    [[ "$dimm_count" =~ ^[0-9]+$ ]] || dimm_count="null"
    [[ "$dimm_speed" =~ ^[0-9]+$ ]] || dimm_speed="null"
  fi

  status="OK"
  (( total_kb < 1024 )) && { issues+=("No RAM detected"); status="NOT_USABLE"; }
  awk -v p="${used_pct:-0}" -v w="$RAM_USAGE_WARN" 'BEGIN{exit !(p >= w)}' && { issues+=("High RAM usage: ${used_pct}%"); [[ "$status" == "OK" ]] && status="DEGRADED"; }

  local issues_json; issues_json=$(printf ',"%s"' "${issues[@]+"${issues[@]}"}"); issues_json="[${issues_json#,}]"
  local swap_free_gb; swap_free_gb=$(awk -v v="${swap_free_kb:-0}" 'BEGIN{printf "%.2f", v/1048576}')
  cat <<EOF
"ram":{
  "total_gb":$total_gb,
  "available_gb":$avail_gb,
  "used_pct":$used_pct,
  "swap_total_gb":$swap_total_gb,
  "swap_free_gb":$swap_free_gb,
  "dimm_slots_populated":$dimm_count,
  "dimm_speed_mhz":$dimm_speed,
  "status":$(jstr "$status"),
  "issues":$issues_json
}
EOF
}

# ── 3. Storage ────────────────────────────────────────────────
collect_storage() {
  local disks=() status="OK" issues=()

  # Enumerate block devices (ignore loop, ram, zram)
  local devs=()
  while IFS= read -r line; do
    [[ "$line" =~ ^(loop|ram|zram) ]] && continue
    devs+=("/dev/$line")
  done < <(ls /sys/block/ 2>/dev/null)

  [[ ${#devs[@]} -eq 0 ]] && { issues+=("No block devices found"); status="NOT_USABLE"; }

  for dev in "${devs[@]}"; do
    local dname; dname=$(basename "$dev")
    local size_bytes=0 rotational="null" smart_ok="null"
    local disk_temp="null" health="UNKNOWN" disk_issues=()

    # Size
    local sz_f="/sys/block/${dname}/size"
    [[ -f "$sz_f" ]] && size_bytes=$(( $(read_file "$sz_f" | tr -d '\n') * 512 ))
    local size_gb; size_gb=$(awk -v b="${size_bytes:-0}" 'BEGIN{printf "%.1f", b/1073741824}')

    # Rotational (0=SSD, 1=HDD)
    local rot_f="/sys/block/${dname}/queue/rotational"
    [[ -f "$rot_f" ]] && rotational=$(read_file "$rot_f" | tr -d '\n')

    # SMART (needs root + kernel support; pure bash via /dev/sg or smartctl)
    if [[ $EUID -eq 0 ]] && command -v smartctl &>/dev/null; then
      local smart_out; smart_out=$(smartctl -H "$dev" 2>/dev/null || true)
      if echo "$smart_out" | grep -q 'PASSED\|OK'; then
        smart_ok="true"; health="HEALTHY"
      elif echo "$smart_out" | grep -q 'FAILED'; then
        smart_ok="false"; health="FAILING"
        disk_issues+=("SMART FAILED on $dname"); status="NOT_USABLE"
      fi
      # Disk temperature via SMART
      local dtemp; dtemp=$(smartctl -A "$dev" 2>/dev/null | awk '/Temperature_Celsius|Airflow_Temperature/{print $10; exit}' || true)
      [[ "$dtemp" =~ ^[0-9]+$ ]] && disk_temp=$dtemp
      (( disk_temp != "null" && ${disk_temp:-0} >= DISK_TEMP_WARN )) 2>/dev/null && {
        disk_issues+=("High disk temp: ${disk_temp}°C"); [[ "$status" == "OK" ]] && status="DEGRADED"
      }
    fi

    # Filesystem usage via /proc/mounts + statfs-via-df (POSIX)
    local mount_points=() fs_usages=()
    while IFS=' ' read -r mdev mpoint _; do
      [[ "$mdev" == "$dev" || "$mdev" == "${dev}1" || "$mdev" == "${dev}p1" ]] || continue
      local dfout; dfout=$(df -k "$mpoint" 2>/dev/null | tail -1) || continue
      local used_k avail_k total_k use_pct
      read -r _ total_k used_k avail_k use_pct _ <<< "$dfout"
      use_pct="${use_pct//%/}"
      mount_points+=("$mpoint")
      fs_usages+=("{\"mount\":$(jstr "$mpoint"),\"total_gb\":$(awk -v k="${total_k:-0}" 'BEGIN{printf "%.1f",k/1048576}'),\"used_pct\":$use_pct}")
      (( use_pct >= DISK_USAGE_WARN )) && {
        disk_issues+=("Disk usage ${use_pct}% on $mpoint"); [[ "$status" == "OK" || "$status" == "DEGRADED" ]] && status="DEGRADED"
      }
    done < /proc/mounts

    local fs_json; fs_json=$(printf ',%s' "${fs_usages[@]+"${fs_usages[@]}"}"); fs_json="[${fs_json#,}]"
    local di_json; di_json=$(printf ',"%s"' "${disk_issues[@]+"${disk_issues[@]}"}"); di_json="[${di_json#,}]"

    disks+=("{
      \"device\":$(jstr "$dname"),
      \"size_gb\":$size_gb,
      \"rotational\":$rotational,
      \"smart_passed\":$smart_ok,
      \"health\":$(jstr "$health"),
      \"temp_celsius\":$disk_temp,
      \"filesystems\":$fs_json,
      \"issues\":$di_json
    }")
  done

  local disks_json; disks_json=$(printf ',%s' "${disks[@]+"${disks[@]}"}"); disks_json="[${disks_json#,}]"
  local issues_json; issues_json=$(printf ',"%s"' "${issues[@]+"${issues[@]}"}"); issues_json="[${issues_json#,}]"
  cat <<EOF
"storage":{
  "devices":$disks_json,
  "status":$(jstr "$status"),
  "issues":$issues_json
}
EOF
}

# ── 4. GPU ────────────────────────────────────────────────────
collect_gpu() {
  local gpus=() status="OK" issues=()

  # Try nvidia-smi (NVIDIA)
  if command -v nvidia-smi &>/dev/null; then
    local smi_out; smi_out=$(nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.total,memory.used,driver_version --format=csv,noheader,nounits 2>/dev/null || true)
    while IFS=',' read -r name temp util mem_total mem_used drv; do
      name=$(echo "$name" | sed 's/^ *//;s/ *$//')
      temp=$(echo "$temp" | tr -d ' ')
      util=$(echo "$util" | tr -d ' ')
      mem_total=$(echo "$mem_total" | tr -d ' ')
      mem_used=$(echo "$mem_used" | tr -d ' ')
      drv=$(echo "$drv" | tr -d ' ')
      local gi=(); [[ "$temp" =~ ^[0-9]+$ ]] && (( temp >= 85 )) && { gi+=("GPU temp critical: ${temp}°C"); status="DEGRADED"; }
      local gi_json; gi_json=$(printf ',"%s"' "${gi[@]+"${gi[@]}"}"); gi_json="[${gi_json#,}]"
      gpus+=("{\"vendor\":\"NVIDIA\",\"name\":$(jstr "$name"),\"driver\":$(jstr "$drv"),\"temp_celsius\":${temp:-null},\"utilization_pct\":${util:-null},\"vram_total_mb\":${mem_total:-null},\"vram_used_mb\":${mem_used:-null},\"issues\":$gi_json}")
    done <<< "$smi_out"
  fi

  # Try ROCm (AMD)
  if command -v rocm-smi &>/dev/null && [[ ${#gpus[@]} -eq 0 ]]; then
    local rout; rout=$(rocm-smi --showtemp --showuse --showmeminfo vram --csv 2>/dev/null | tail -n +2 || true)
    while IFS=',' read -r _ temp util _ _ _; do
      gpus+=("{\"vendor\":\"AMD\",\"temp_celsius\":${temp:-null},\"utilization_pct\":${util:-null},\"issues\":[]}")
    done <<< "$rout"
  fi

  # Fallback: PCI scan
  if [[ ${#gpus[@]} -eq 0 ]]; then
    if command -v lspci &>/dev/null; then
      while IFS= read -r line; do
        local gname; gname=$(echo "$line" | sed 's/.*: //')
        gpus+=("{\"vendor\":\"Unknown\",\"name\":$(jstr "$gname"),\"temp_celsius\":null,\"utilization_pct\":null,\"issues\":[]}")
      done < <(lspci 2>/dev/null | grep -i 'vga\|3d\|display' || true)
    fi
    # Kernel DRM devices
    if [[ ${#gpus[@]} -eq 0 ]]; then
      for drm in /sys/class/drm/card*/device/uevent; do
        [[ -f "$drm" ]] || continue
        local drm_name; drm_name=$(grep 'PCI_ID\|DRIVER' "$drm" 2>/dev/null | tr '\n' ' ' || echo "DRM GPU")
        gpus+=("{\"vendor\":\"DRM\",\"name\":$(jstr "$drm_name"),\"temp_celsius\":null,\"utilization_pct\":null,\"issues\":[]}")
        break
      done
    fi
  fi

  [[ ${#gpus[@]} -eq 0 ]] && { issues+=("No GPU detected"); gpus+=("{\"vendor\":\"None\",\"name\":\"Not Found\",\"issues\":[\"No GPU detected\"]}"); }

  local gpus_json; gpus_json=$(printf ',%s' "${gpus[@]+"${gpus[@]}"}"); gpus_json="[${gpus_json#,}]"
  local issues_json; issues_json=$(printf ',"%s"' "${issues[@]+"${issues[@]}"}"); issues_json="[${issues_json#,}]"
  cat <<EOF
"gpu":{
  "devices":$gpus_json,
  "status":$(jstr "$status"),
  "issues":$issues_json
}
EOF
}

# ── 5. Network ────────────────────────────────────────────────
collect_network() {
  local ifaces=() status="OK" issues=()
  local has_active=false

  for iface_dir in /sys/class/net/*/; do
    local iface; iface=$(basename "$iface_dir")
    [[ "$iface" == "lo" ]] && continue

    local operstate; operstate=$(read_file "${iface_dir}operstate" | tr -d '\n')
    local carrier; carrier=$(read_file "${iface_dir}carrier"   | tr -d '\n' 2>/dev/null || echo "0")
    local speed;   speed=$(  read_file "${iface_dir}speed"     | tr -d '\n' 2>/dev/null || echo "null")
    local mac;     mac=$(    read_file "${iface_dir}address"   | tr -d '\n')
    [[ "$speed" =~ ^-?[0-9]+$ ]] || speed="null"
    [[ "$speed" == "-1" ]] && speed="null"

    # RX/TX bytes
    local rx_bytes tx_bytes
    rx_bytes=$(read_file "${iface_dir}statistics/rx_bytes" | tr -d '\n' || echo 0)
    tx_bytes=$(read_file "${iface_dir}statistics/tx_bytes" | tr -d '\n' || echo 0)
    local rx_errors; rx_errors=$(read_file "${iface_dir}statistics/rx_errors" | tr -d '\n' || echo 0)
    local tx_errors; tx_errors=$(read_file "${iface_dir}statistics/tx_errors" | tr -d '\n' || echo 0)

    # IP address
    local ip="null"
    if command -v ip &>/dev/null; then
      ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2; exit}' || true)
      [[ -z "$ip" ]] && ip="null" || ip=$(jstr "$ip")
    fi
    [[ "$ip" == "null" ]] && ip="null"  # ensure literal null not quoted

    [[ "$operstate" == "up" && "$carrier" == "1" ]] && has_active=true

    local ni=()
    (( rx_errors > 1000 )) && ni+=("High RX errors: $rx_errors on $iface")
    (( tx_errors > 1000 )) && ni+=("High TX errors: $tx_errors on $iface")
    local ni_json; ni_json=$(printf ',"%s"' "${ni[@]+"${ni[@]}"}"); ni_json="[${ni_json#,}]"

    ifaces+=("{
      \"interface\":$(jstr "$iface"),
      \"state\":$(jstr "$operstate"),
      \"carrier\":$(jstr "$carrier"),
      \"mac\":$(jstr "$mac"),
      \"ip_cidr\":$ip,
      \"speed_mbps\":$speed,
      \"rx_bytes\":$rx_bytes,
      \"tx_bytes\":$tx_bytes,
      \"rx_errors\":$rx_errors,
      \"tx_errors\":$tx_errors,
      \"issues\":$ni_json
    }")
  done

  $has_active || { issues+=("No active network interface"); status="DEGRADED"; }
  [[ ${#ifaces[@]} -eq 0 ]] && { issues+=("No network interfaces found"); status="NOT_USABLE"; }

  local ifaces_json; ifaces_json=$(printf ',%s' "${ifaces[@]+"${ifaces[@]}"}"); ifaces_json="[${ifaces_json#,}]"
  local issues_json; issues_json=$(printf ',"%s"' "${issues[@]+"${issues[@]}"}"); issues_json="[${issues_json#,}]"
  cat <<EOF
"network":{
  "interfaces":$ifaces_json,
  "status":$(jstr "$status"),
  "issues":$issues_json
}
EOF
}

# ── 6. System meta ────────────────────────────────────────────
collect_system() {
  local os kernel uptime_s uptime_h bios_vendor bios_version board_name
  local boot_time

  os=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown}" || uname -o)
  kernel=$(uname -r)
  read uptime_s _ < /proc/uptime
  uptime_h=$(awk -v s="${uptime_s:-0}" 'BEGIN{printf "%.1f", s/3600}')
  local _boot_epoch; _boot_epoch=$(awk -v now="$(date +%s)" -v s="${uptime_s:-0}" 'BEGIN{print int(now-s)}')
  boot_time=$(date -d "@${_boot_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

  bios_vendor=$(  read_file /sys/class/dmi/id/bios_vendor  | tr -d '\n' || echo "Unknown")
  bios_version=$( read_file /sys/class/dmi/id/bios_version | tr -d '\n' || echo "Unknown")
  board_name=$(   read_file /sys/class/dmi/id/board_name   | tr -d '\n' || echo "Unknown")

  cat <<EOF
"system":{
  "hostname":$(jstr "$HOSTNAME_LABEL"),
  "os":$(jstr "$os"),
  "kernel":$(jstr "$kernel"),
  "uptime_hours":$uptime_h,
  "boot_time":$(jstr "$boot_time"),
  "bios_vendor":$(jstr "$bios_vendor"),
  "bios_version":$(jstr "$bios_version"),
  "board":$(jstr "$board_name"),
  "run_as_root":$(jbool "$EUID")
}
EOF
}

# ── 7. Overall usability verdict ─────────────────────────────
determine_usability() {
  local cpu_s="$1" ram_s="$2" storage_s="$3" net_s="$4"
  local score=0

  [[ "$cpu_s"     == "NOT_USABLE" ]] && (( score+=10 ))
  [[ "$ram_s"     == "NOT_USABLE" ]] && (( score+=10 ))
  [[ "$storage_s" == "NOT_USABLE" ]] && (( score+=10 ))
  [[ "$cpu_s"     == "DEGRADED"   ]] && (( score+=2  ))
  [[ "$ram_s"     == "DEGRADED"   ]] && (( score+=2  ))
  [[ "$storage_s" == "DEGRADED"   ]] && (( score+=2  ))
  [[ "$net_s"     == "DEGRADED"   ]] && (( score+=1  ))
  [[ "$net_s"     == "NOT_USABLE" ]] && (( score+=2  ))

  if   (( score >= 10 )); then echo "NOT_USABLE"
  elif (( score >= 2  )); then echo "DEGRADED"
  else                        echo "FULLY_USABLE"
  fi
}

# ── Main ──────────────────────────────────────────────────────
main() {
  echo -e "\n${BLD}╔══════════════════════════════════════════╗"
  echo    "║    PC Lab Watch - Hardware Monitor v2.0  ║"
  echo -e "╚══════════════════════════════════════════╝${RST}\n"

  [[ $EUID -ne 0 ]] && warn "Not running as root. SMART, BIOS and temperature data may be limited."

  mkdir -p "$REPORT_DIR"

  log "Collecting CPU…"
  CPU_JSON=$(collect_cpu)
  CPU_STATUS=$(echo "$CPU_JSON" | grep '"status"' | head -1 | sed 's/.*"status":"\([^"]*\)".*/\1/')

  log "Collecting RAM…"
  RAM_JSON=$(collect_ram)
  RAM_STATUS=$(echo "$RAM_JSON" | grep '"status"' | head -1 | sed 's/.*"status":"\([^"]*\)".*/\1/')

  log "Collecting Storage…"
  STOR_JSON=$(collect_storage)
  STOR_STATUS=$(echo "$STOR_JSON" | grep '"status"' | head -1 | sed 's/.*"status":"\([^"]*\)".*/\1/')

  log "Collecting GPU…"
  GPU_JSON=$(collect_gpu)

  log "Collecting Network…"
  NET_JSON=$(collect_network)
  NET_STATUS=$(echo "$NET_JSON" | grep '"status"' | head -1 | sed 's/.*"status":"\([^"]*\)".*/\1/')

  log "Collecting System meta…"
  SYS_JSON=$(collect_system)

  USABILITY=$(determine_usability "$CPU_STATUS" "$RAM_STATUS" "$STOR_STATUS" "$NET_STATUS")

  # Assemble JSON
  cat > "$REPORT_FILE" <<EOF
{
  "schema_version": "2.0",
  "generated_at": "$TIMESTAMP",
  "usability": "$USABILITY",
  $SYS_JSON,
  $CPU_JSON,
  $RAM_JSON,
  $STOR_JSON,
  $GPU_JSON,
  $NET_JSON
}
EOF

  # Pretty-print summary
  echo ""
  echo -e "${BLD}══════════════ SUMMARY ══════════════${RST}"
  printf "  %-12s  %s\n" "CPU:"     "$CPU_STATUS"
  printf "  %-12s  %s\n" "RAM:"     "$RAM_STATUS"
  printf "  %-12s  %s\n" "Storage:" "$STOR_STATUS"
  printf "  %-12s  %s\n" "Network:" "$NET_STATUS"
  echo   "  ─────────────────────────────────────"

  case "$USABILITY" in
    FULLY_USABLE) echo -e "  ${GRN}${BLD}USABILITY: $USABILITY${RST}" ;;
    DEGRADED)     echo -e "  ${YLW}${BLD}USABILITY: $USABILITY${RST}" ;;
    NOT_USABLE)   echo -e "  ${RED}${BLD}USABILITY: $USABILITY${RST}" ;;
  esac
  echo ""

  ok "Report saved → $REPORT_FILE"

  # Optional: POST to central server
  if [[ -n "$CENTRAL_URL" ]]; then
    log "Sending report to $CENTRAL_URL …"
    if command -v curl &>/dev/null; then
      curl -fsSL -X POST -H "Content-Type: application/json" \
           -d "@$REPORT_FILE" "$CENTRAL_URL" && ok "Report sent." || warn "Failed to send report."
    elif command -v wget &>/dev/null; then
      wget -qO- --header="Content-Type: application/json" \
           --post-file="$REPORT_FILE" "$CENTRAL_URL" && ok "Report sent." || warn "Failed to send report."
    else
      warn "Neither curl nor wget found; cannot send report."
    fi
  fi

  echo ""
  echo -e "${CYN}Tip: View report with: ${BLD}cat $REPORT_FILE | python3 -m json.tool${RST}"
  echo -e "${CYN}     Or open lab_watch_dashboard.html in a browser for a visual view.${RST}\n"
}

main "$@"
