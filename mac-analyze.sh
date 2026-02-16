#!/bin/bash

# Mac Metrics Analyzer - View and analyze historical metrics
# Reads from CSV logs and generates reports

set -euo pipefail

# Configuration
LOG_DIR="${HOME}/logs/mac-metrics"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

get_csv_files() {
    ls -1 "${LOG_DIR}"/*.csv 2>/dev/null | sort
}

get_latest_csv() {
    ls -t "${LOG_DIR}"/*.csv 2>/dev/null | head -1
}

parse_time_range() {
    local range=$1
    local start_date end_date
    case "$range" in
        today) start_date=$(date +%Y-%m-%d); end_date=$start_date ;;
        yesterday) start_date=$(date -v-1d +%Y-%m-%d); end_date=$start_date ;;
        week) start_date=$(date -v-7d +%Y-%m-%d); end_date=$(date +%Y-%m-%d) ;;
        month) start_date=$(date -v-30d +%Y-%m-%d); end_date=$(date +%Y-%m-%d) ;;
        *) echo "Invalid time range: $range" >&2; return 1 ;;
    esac
    echo "${start_date} ${end_date}"
}

format_mb() {
    local mb=$1
    if [[ $mb -ge 1024 ]]; then
        local gb=$(echo "scale=1; $mb / 1024" | bc 2>/dev/null || echo "$((mb/1024))")
        echo "${gb} GB"
    else
        echo "${mb} MB"
    fi
}

get_memory_pressure() {
    local pressure_output=$(memory_pressure 2>/dev/null | head -5)
    local free_pct=$(echo "$pressure_output" | grep -oE '[0-9]+%' | head -1 || echo "?%")
    local status
    if echo "$free_pct" | grep -qE '^[6-9][0-9]%'; then status="Good"
    elif echo "$free_pct" | grep -qE '^[3-5][0-9]%'; then status="Moderate"
    elif echo "$free_pct" | grep -qE '^[1-2][0-9]%'; then status="High"
    else status="Critical"
    fi
    echo "${free_pct}|${status}"
}

get_current_process_memory() {
    ps aux | sort -nrk 4 | head -20 | awk '{
        rss_mb = $6/1024
        cmd = $11
        for(i=12;i<=NF;i++) cmd = cmd " " $i
        if (rss_mb > 50 && cmd !~ /^\[/) 
            printf "%s|%.0f\n", cmd, rss_mb
    }' | head -15
}

draw_ascii_chart() {
    local title=$1; local values=$2; local width=${3:-50}
    echo -e "${BOLD}${title}${NC}"
    local max=0
    for val in $values; do max=$(( (val > max) ? val : max )); done
    [[ $max -eq 0 ]] && max=1
    local i=0
    for val in $values; do
        local bar_len=$(( (val * width) / max ))
        local bar=""
        for ((j=0; j<bar_len; j++)); do bar+="="; done
        printf "%3d | %s\n" "$val" "$bar"
        ((i++)); [[ $i -gt 20 ]] && break
    done
    echo ""
}

# ============================================================================
# REPORT FUNCTIONS
# ============================================================================

show_summary() {
    local file=$1; local range=${2:-"all"}
    echo -e "${BOLD}${CYAN}=== Mac Metrics Summary ===${NC}"
    echo -e "${YELLOW}Data source:${NC} $(basename "$file")"
    if [[ "$range" != "all" ]]; then
        read -r start_date end_date <<< "$(parse_time_range "$range")"
        echo -e "${YELLOW}Time range:${NC} ${start_date} to ${end_date}"
    fi
    echo ""
    local total_samples=$(tail -n +2 "$file" | wc -l | tr -d ' ')
    echo -e "${GREEN}Total samples:${NC} ${total_samples}"
    local total_ram_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024)}')
    total_ram_mb=${total_ram_mb:-24576}
    local pressure_info=$(get_memory_pressure)
    local free_pct=$(echo "$pressure_info" | cut -d'|' -f1)
    local status=$(echo "$pressure_info" | cut -d'|' -f2)
    echo -e "${BOLD}${GREEN}CPU USAGE (%)${NC}"
    echo -e "  Average: ${YELLOW}$(tail -n +2 "$file" | cut -d, -f2 | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print 0}')%${NC}"
    echo -e "  Max:     ${RED}$(tail -n +2 "$file" | cut -d, -f2 | sort -n | tail -1)%${NC}"
    echo ""
    echo -e "${BOLD}${GREEN}MEMORY USAGE${NC}"
    local mem_avg=$(tail -n +2 "$file" | cut -d, -f9 | awk '{sum+=$1; count++} END {if(count>0) print int(sum/count); else print 0}')
    local mem_max=$(tail -n +2 "$file" | cut -d, -f9 | sort -n | tail -1)
    echo -e "  Average Used: ${YELLOW}$(format_mb $mem_avg)${NC} ($(echo "scale=1; $mem_avg * 100 / $total_ram_mb" | bc 2>/dev/null || echo "0")% of RAM)"
    echo -e "  Max Used:     ${RED}$(format_mb $mem_max)${NC} ($(echo "scale=1; $mem_max * 100 / $total_ram_mb" | bc 2>/dev/null || echo "0")% of RAM)"
    echo -e "  Total RAM:    ${CYAN}$(format_mb $total_ram_mb)${NC}"
    local health_color=$([[ "$status" == "Good" ]] && echo "$GREEN" || echo "$YELLOW")
    echo -e "  Current Pressure: ${health_color}${status} (${free_pct} free)${NC}"
    echo ""
}

show_top_offenders() {
    local file=$1; local hours=${2:-24}
    local total_ram_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024)}')
    total_ram_mb=${total_ram_mb:-24576}
    local pressure_info=$(get_memory_pressure)
    local free_pct=$(echo "$pressure_info" | cut -d'|' -f1)
    local status=$(echo "$pressure_info" | cut -d'|' -f2)
    echo -e "${BOLD}${CYAN}=== Top Resource Consumers ===${NC}"
    echo ""
    echo -e "${BOLD}${GREEN}CURRENT MEMORY USAGE (right now)${NC}"
    echo -e "${YELLOW}Memory Pressure: ${status} (${free_pct} free)${NC}"
    echo ""
    local total_current=0
    while IFS='|' read -r cmd mb; do
        [[ -z "$cmd" ]] && continue
        local pct=$(echo "scale=1; $mb * 100 / $total_ram_mb" | bc 2>/dev/null || echo "0")
        total_current=$((total_current + mb))
        printf "  %-40s %8s  (%5.1f%%)\n" "${cmd:0:40}" "$(format_mb ${mb%.*})" "$pct"
    done <<< "$(get_current_process_memory)"
    echo ""
    echo -e "  ${BOLD}Total (top 15): $(format_mb ${total_current})${NC}"
    echo ""
    echo -e "${BOLD}${GREEN}HISTORICAL AVERAGE (last ${hours}h)${NC}"
    python3 - "$file" "$hours" <<'PYTHON_SCRIPT'
import sys, json, re
from collections import defaultdict
file_path, hours = sys.argv[1], int(sys.argv[2])
cpu_avgs, mem_avgs = defaultdict(list), defaultdict(list)
with open(file_path, 'r') as f:
    next(f)
    for line in f:
        matches = re.findall(r'"\[({.*?})\]"', line)
        for i, match in enumerate(matches):
            try:
                data = json.loads('[' + match + ']')
                for item in data:
                    cmd = item.get('cmd', 'Unknown')
                    if i == 0 and 'cpu' in item: cpu_avgs[cmd].append(float(item['cpu']))
                    elif i == 1 and 'rss_mb' in item: mem_avgs[cmd].append(int(item['rss_mb']))
            except: continue
print("\033[1;33mTOP BY MEMORY (historic avg)\033[0m")
sorted_mem = sorted(mem_avgs.items(), key=lambda x: sum(x[1])/len(x[1]), reverse=True)[:10]
for cmd, vals in sorted_mem:
    avg = int(sum(vals)/len(vals))
    display = f"{avg/1024:.1f} GB" if avg >= 1024 else f"{avg} MB"
    print(f"  {cmd[:40]:40} {display}")
PYTHON_SCRIPT
    echo ""
}

show_health() {
    echo -e "${BOLD}${CYAN}=== System Health Check ===${NC}"
    echo ""
    local total_ram_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024)}')
    local pressure_info=$(get_memory_pressure)
    local free_pct=$(echo "$pressure_info" | cut -d'|' -f1)
    local status=$(echo "$pressure_info" | cut -d'|' -f2)
    local used_mb=$(vm_stat 2>/dev/null | awk '/Pages active/ {active=$3} /Pages wired/ {wired=$4} END {gsub(/\./,"",active); gsub(/\./,"",wired); print int((active+wired)*16/1024)}')
    local swap_mb=$(sysctl -n vm.swapused 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}' || echo "0")
    local status_color=$([[ "$status" == "Good" ]] && echo "$GREEN" || echo "$YELLOW")
    echo -e "Memory:  ${status_color}${status}${NC} (${BOLD}${free_pct}${NC} free, ${used_mb}/${total_ram_mb} MB used)"
    echo -e "Swap:    ${swap_mb} MB used"
    echo ""
    echo -e "${BOLD}Top 3 Memory Consumers:${NC}"
    ps aux | sort -nrk 4 | head -3 | awk '{printf "  %-35s %s\n", substr($11,1,35), int($6/1024)" MB"}'
    echo ""
    if [[ "$status" == "Good" && "$swap_mb" -eq 0 ]]; then echo -e "✓ ${GREEN}System is healthy${NC}";
    elif [[ "$status" == "Good" ]]; then echo -e "! ${YELLOW}System healthy, but using swap${NC}";
    else echo -e "⚠  ${RED}Memory pressure detected${NC}"; fi
}

show_compare() {
    local file=$1; local minutes=${2:-30}
    echo -e "${BOLD}${CYAN}=== Memory Comparison (vs ${minutes}m ago) ===${NC}"
    local now_mb=$(vm_stat 2>/dev/null | awk '/Pages active/ {a=$3} /Pages wired/ {w=$4} END {gsub(/\./,"",a); gsub(/\./,"",w); print int((a+w)*16/1024)}')
    local target_time=$(date -v-${minutes}m -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
    local old_mb=$(tail -n +2 "$file" | awk -F, -v t="$target_time" '$1 <= t {m=$9} END {print m}')
    if [[ -z "$old_mb" || "$old_mb" == "0" ]]; then echo "No historical sample found for comparison."; return; fi
    local diff=$((now_mb - old_mb))
    if [[ $diff -lt -50 ]]; then echo -e "⬇  Memory ${GREEN}IMPROVED${NC} by $(format_mb ${diff#-})";
    elif [[ $diff -gt 50 ]]; then echo -e "⬆  Memory ${YELLOW}INCREASED${NC} by $(format_mb $diff)";
    else echo "↔  Memory stable (change < 50MB)"; fi
    echo -e "  Now: $(format_mb $now_mb) | Then: $(format_mb $old_mb)"
}

show_trends() {
    local file=$1; local metric=${2:-"cpu"}; local interval=${3:-"hourly"}
    local metric_upper=$(echo "$metric" | tr '[:lower:]' '[:upper:]')
    echo -e "${BOLD}${CYAN}=== ${metric_upper} Trends ===${NC}"
    echo -e "${YELLOW}Interval: ${interval}${NC}"
    local col=2; local title="CPU Usage (%)"
    case "$metric" in
        memory|mem) col=9; title="Memory Used (MB)" ;;
        disk) col=17; title="Disk Usage (%)" ;;
        network|net) col=18; title="Network In (MB)" ;;
    esac
    local values=""
    if [[ "$interval" == "hourly" ]]; then
        values=$(tail -n +2 "$file" | awk -F, -v c="$col" '{split($1,t,"T"); h=substr(ts[2],1,2); k=t[1]" "h":00"; s[k]+=$c; n[k]++} END {for(k in s) print k, int(s[k]/n[k])}' | sort | awk '{print $NF}')
    else
        values=$(tail -n +2 "$file" | tail -30 | cut -d, -f"$col")
    fi
    draw_ascii_chart "$title" "$values" 40
}

show_recent() {
    local file=$1; local count=${2:-10}
    echo -e "${BOLD}${CYAN}=== Most Recent ${count} Samples ===${NC}"
    { echo "Timestamp,CPU%,Mem,Disk%"; tail -n +2 "$file" | tail -"$count" | awk -F, '{printf "%s,%.1f,%d,%.1f\n", $1, $2, $9, $17}'; } | column -t -s,
}

show_help() {
    cat <<EOF
Mac Metrics Analyzer - View and analyze system performance

Usage: mac-analyze [command] [options]

Commands:
  summary [period]      Show statistics (today|yesterday|week|month)
  offenders [hours]     Show top resource consumers (now vs historical)
  health                Quick system health check
  compare [minutes]     Compare current memory vs N minutes ago
  trends [metric] [int] Show trends (metric: cpu|mem|disk|net, int: hourly|raw)
  recent [N]            Show last N samples
  watch [seconds]       Live monitoring (default: 5s)
  files                 List available log files
  help                  Show this help

Examples:
  mac-analyze offenders 24
  mac-analyze health
  mac-analyze compare 60
EOF
}

watch_live() {
    local rate=${1:-5}; local cmd=$(command -v mac-monitor || echo "~/scripts/mac-monitor.sh")
    while true; do clear; "$cmd"; sleep "$rate"; done
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    local cmd=${1:-"summary"}
    [[ "$cmd" == "help" || "$cmd" == "--help" || "$cmd" == "-h" ]] && { show_help; return 0; }
    [[ "$cmd" == "watch" ]] && { watch_live "${2:-5}"; return 0; }
    [[ "$cmd" == "health" ]] && { show_health; return 0; }
    [[ "$cmd" == "files" ]] && { echo -e "${BOLD}${CYAN}Log Files:${NC}"; get_csv_files | xargs ls -lh | awk '{print "  "$9" ("$5")"}'; return 0; }
    local file=$(get_latest_csv)
    [[ ! -f "$file" ]] && { echo -e "${RED}No logs found.${NC}"; exit 1; }
    case "$cmd" in
        summary) show_summary "$file" "${2:-all}" ;;
        offenders) show_top_offenders "$file" "${2:-24}" ;;
        compare) show_compare "$file" "${2:-30}" ;;
        trends) show_trends "$file" "${2:-cpu}" "${3:-hourly}" ;;
        recent) show_recent "$file" "${2:-10}" ;;
        *) echo "Unknown command: $cmd. Try 'mac-analyze help'"; exit 1 ;;
    esac
}

main "${@:-}"
