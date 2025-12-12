#!/usr/bin/env bash
set -Eeuo pipefail

# Usage:
#   ./script2_sysmon.sh START
#   ./script2_sysmon.sh STOP
#   ./script2_sysmon.sh STATUS
#
# CSV format:
# timestamp;all_memory_MB;free_memory_MB;%memory_used;%cpu_used;%disk_used;load_average_1m

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="$SCRIPT_DIR/.sysmon.pid"
LOGFILE="$SCRIPT_DIR/.sysmon.log"
INTERVAL_SEC=600  # 10 minutes

uname_s="$(uname -s)"

is_running() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

cpu_usage_pct() {
  case "$uname_s" in
    Linux)
      local cpu u1 n1 s1 id1 io1 ir1 si1 st1 g1 gn1
      local u2 n2 s2 id2 io2 ir2 si2 st2 g2 gn2
      read -r cpu u1 n1 s1 id1 io1 ir1 si1 st1 g1 gn1 < /proc/stat
      sleep 1
      read -r cpu u2 n2 s2 id2 io2 ir2 si2 st2 g2 gn2 < /proc/stat
      local idle0=$((id1 + io1))
      local nonidle0=$((u1 + n1 + s1 + ir1 + si1 + st1))
      local total0=$((idle0 + nonidle0))
      local idle1=$((id2 + io2))
      local nonidle1=$((u2 + n2 + s2 + ir2 + si2 + st2))
      local total1=$((idle1 + nonidle1))
      local totald=$((total1 - total0))
      local idled=$((idle1 - idle0))
      awk -v td="$totald" -v id="$idled" 'BEGIN { if (td<=0) {print "0.00"} else {printf "%.2f", (td-id)/td*100} }'
      ;;
    Darwin)
      # Use second sample from top
      local idle
      idle="$(top -l 2 -s 1 -n 0 | awk -F',' '/CPU usage/ {for(i=1;i<=NF;i++){if($i~ /idle/){gsub(/[^0-9.]/,"",$i); print $i}}}' | tail -1)"
      awk -v id="${idle:-0}" 'BEGIN { if (id<0 || id>100) id=0; printf "%.2f", 100-id }'
      ;;
    *)
      echo "0.00"
      ;;
  esac
}

mem_stats() {
  # Output: all_MB free_MB used_pct
  case "$uname_s" in
    Linux)
      local mt ma
      mt="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
      ma="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
      if [[ -z "${mt:-}" || -z "${ma:-}" ]]; then
        mt="$(free -k | awk 'NR==2 {print $2}')"
        ma="$(free -k | awk 'NR==2 {print $7}')"
      fi
      local all_mb free_mb used_pct
      all_mb="$(awk -v m="$mt" 'BEGIN {printf "%.0f", m/1024}')"
      free_mb="$(awk -v m="$ma" 'BEGIN {printf "%.0f", m/1024}')"
      used_pct="$(awk -v t="$mt" -v a="$ma" 'BEGIN { if (t<=0) print "0.00"; else printf "%.2f", (t-a)/t*100 }')"
      echo "$all_mb" "$free_mb" "$used_pct"
      ;;
    Darwin)
      local pagesize total_bytes free_pages spec_pages free_bytes total_mb free_mb used_pct
      pagesize="$(sysctl -n hw.pagesize)"
      total_bytes="$(sysctl -n hw.memsize)"
      free_pages="$(vm_stat | awk '/Pages free/ {gsub(/\./,""); print $3}')"
      spec_pages="$(vm_stat | awk '/Pages speculative/ {gsub(/\./,""); print $3}')"
      free_pages="${free_pages:-0}"
      spec_pages="${spec_pages:-0}"
      free_bytes=$(( (free_pages + spec_pages) * pagesize ))
      total_mb="$(awk -v b="$total_bytes" 'BEGIN {printf "%.0f", b/1024/1024}')"
      free_mb="$(awk -v b="$free_bytes" 'BEGIN {printf "%.0f", b/1024/1024}')"
      if [[ "${total_mb:-0}" -le 0 ]]; then
        echo "0 0 0.00"
        return
      fi
      used_pct="$(awk -v t="$total_mb" -v f="$free_mb" 'BEGIN {printf "%.2f", (t-f)/t*100 }')"
      echo "$total_mb" "$free_mb" "$used_pct"
      ;;
    *)
      echo "0 0 0.00"
      ;;
  esac
}

disk_root_used_pct() {
  df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

loadavg_1m() {
  case "$uname_s" in
    Linux)
      awk '{print $1}' /proc/loadavg
      ;;
    Darwin)
      sysctl -n vm.loadavg 2>/dev/null | tr -d '{},' | awk '{print $1}'
      ;;
    *)
      echo "0.00"
      ;;
  esac
}

write_metrics_once() {
  local ts all_mb free_mb mem_used_pct cpu_pct disk_pct load1 csv_file
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  read -r all_mb free_mb mem_used_pct < <(mem_stats)
  cpu_pct="$(cpu_usage_pct)"
  disk_pct="$(disk_root_used_pct)"
  load1="$(loadavg_1m)"
  csv_file="$SCRIPT_DIR/system_report_$(date +%F).csv"
  echo "${ts};${all_mb};${free_mb};${mem_used_pct};${cpu_pct};${disk_pct};${load1}" >> "$csv_file"
}

daemon_loop() {
  echo $$ > "$PIDFILE"
  trap 'rm -f "$PIDFILE"; exit 0' INT TERM
  while true; do
    write_metrics_once
    sleep "$INTERVAL_SEC"
  done
}

case "${1:-}" in
  START)
    if is_running; then
      echo "Already running. PID: $(cat "$PIDFILE")"
      exit 0
    fi
    nohup bash "$0" __DAEMON__ >>"$LOGFILE" 2>&1 &
    sleep 0.2
    if is_running; then
      echo "Started. PID: $(cat "$PIDFILE")"
    else
      echo "Error: failed to start. See log: $LOGFILE" >&2
      exit 1
    fi
    ;;
  STOP)
    if is_running; then
      pid="$(cat "$PIDFILE")"
      kill "$pid" 2>/dev/null || true
      for i in {1..10}; do
        if kill -0 "$pid" 2>/dev/null; then
          sleep 0.5
        else
          break
        fi
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "Process did not stop gracefully, sending SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
      fi
      rm -f "$PIDFILE"
      echo "Stopped."
    else
      echo "Not running."
    fi
    ;;
  STATUS)
    if is_running; then
      echo "Running. PID: $(cat "$PIDFILE")"
    else
      echo "Not running."
    fi
    ;;
  __DAEMON__)
    daemon_loop
    ;;
  *)
    echo "Usage: $0 START|STOP|STATUS" >&2
    exit 1
    ;;
esac
