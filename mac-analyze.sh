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
    # Get all CSV files in log directory
    ls -1 "${LOG_DIR}"/*.csv 2>/dev/null | sort
}

get_latest_csv() {
    # Get the most recent CSV file
    ls -t "${LOG_DIR}"/*.csv 2>/dev/null | head -1
}

parse_time_range() {
    local range=$1
    local start_date end_date
    
    case "$range" in
        today)
            start_date=$(date +%Y-%m-%d)
            end_date=$start_date
            ;;
        yesterday)
            start_date=$(date -v-1d +%Y-%m-%d)
            end_date=$start_date
            ;;
        week)
            start_date=$(date -v-7d +%Y-%m-%d)
            end_date=$(date +%Y-%m-%d)
            ;;
        month)
            start_date=$(date -v-30d +%Y-%m-%d)
            end_date=$(date +%Y-%m-%d)
            ;;
        *)
            echo "Invalid time range: $range" >&2
            return 1
            ;;
    esac
    
    echo "${start_date} ${end_date}"
}

draw_ascii_chart() {
    # Draw a simple ASCII bar chart
    local title=$1
    local values=$2  # Space-separated values
    local width=${3:-50}
    
    echo -e "${BOLD}${title}${NC}"
    
    local max=0
    for val in $values; do
        max=$(( (val > max) ? val : max ))
    done
    
    # Prevent division by zero
    [[ $max -eq 0 ]] && max=1
    
    local i=0
    for val in $values; do
        local bar_len=$(( (val * width) / max ))
        local bar=""
        for ((j=0; j<bar_len; j++)); do
            bar+="="
        done
        printf "%3d | %s\n" "$val" "$bar"
        ((i++))
        [[ $i -gt 20 ]] && break  # Limit chart size
    done
    
    echo ""
}

# ============================================================================
# REPORT FUNCTIONS
# ============================================================================

show_summary() {
    local file=$1
    local range=${2:-"all"}
    
    echo -e "${BOLD}${CYAN}=== Mac Metrics Summary ===${NC}"
    echo -e "${YELLOW}Data source:${NC} $(basename "$file")"
    
    if [[ "$range" != "all" ]]; then
        read -r start_date end_date <<< "$(parse_time_range "$range")"
        echo -e "${YELLOW}Time range:${NC} ${start_date} to ${end_date}"
    fi
    echo ""
    
    # Count samples
    local total_samples
    total_samples=$(tail -n +2 "$file" | wc -l | tr -d ' ')
    echo -e "${GREEN}Total samples:${NC} ${total_samples}"
    echo ""
    
    # CPU Statistics
    echo -e "${BOLD}${GREEN}CPU USAGE (%)${NC}"
    local cpu_avg cpu_max cpu_min
    cpu_avg=$(tail -n +2 "$file" | cut -d, -f2 | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print 0}')
    cpu_max=$(tail -n +2 "$file" | cut -d, -f2 | sort -n | tail -1)
    cpu_min=$(tail -n +2 "$file" | cut -d, -f2 | sort -n | head -1)
    
    echo -e "  Average: ${YELLOW}${cpu_avg}%${NC}"
    echo -e "  Max:     ${RED}${cpu_max}%${NC}"
    echo -e "  Min:     ${GREEN}${cpu_min}%${NC}"
    echo ""
    
    # Memory Statistics
    echo -e "${BOLD}${GREEN}MEMORY USAGE (MB)${NC}"
    local mem_avg mem_max mem_total
    mem_avg=$(tail -n +2 "$file" | cut -d, -f9 | awk '{sum+=$1; count++} END {if(count>0) print int(sum/count); else print 0}')
    mem_max=$(tail -n +2 "$file" | cut -d, -f9 | sort -n | tail -1)
    mem_total=$(tail -n +2 "$file" | cut -d, -f8 | head -1)  # total_mem_mb from first data row
    
    echo -e "  Average Used: ${YELLOW}${mem_avg} MB${NC}"
    echo -e "  Max Used:     ${RED}${mem_max} MB${NC}"
    echo -e "  Total RAM:    ${CYAN}${mem_total} MB${NC}"
    echo ""
    
    # Disk Statistics
    echo -e "${BOLD}${GREEN}DISK USAGE (%)${NC}"
    local disk_avg disk_max
    disk_avg=$(tail -n +2 "$file" | cut -d, -f17 | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print 0}')
    disk_max=$(tail -n +2 "$file" | cut -d, -f17 | sort -n | tail -1)
    
    echo -e "  Average: ${YELLOW}${disk_avg}%${NC}"
    echo -e "  Max:     ${RED}${disk_max}%${NC}"
    echo ""
    
    # Network Statistics
    echo -e "${BOLD}${GREEN}NETWORK (MB)${NC}"
    local net_in_max net_out_max
    net_in_max=$(tail -n +2 "$file" | cut -d, -f18 | sort -n | tail -1)
    net_out_max=$(tail -n +2 "$file" | cut -d, -f19 | sort -n | tail -1)
    
    echo -e "  Total In:  ${CYAN}${net_in_max} MB${NC}"
    echo -e "  Total Out: ${CYAN}${net_out_max} MB${NC}"
    echo ""
}

show_top_offenders() {
    local file=$1
    local hours=${2:-24}
    
    echo -e "${BOLD}${CYAN}=== Top Resource Consumers ===${NC}"
    echo -e "${YELLOW}Analyzing last ${hours} hours of data${NC}"
    echo ""
    
    # Use Python to parse the CSV and extract JSON arrays properly
    # This is more reliable than shell parsing for complex JSON
    python3 - "$file" <<'PYTHON_SCRIPT'
import sys
import json
import re
from collections import defaultdict

file_path = sys.argv[1]

cpu_totals = defaultdict(float)
cpu_counts = defaultdict(int)
mem_totals = defaultdict(int)
mem_counts = defaultdict(int)

with open(file_path, 'r') as f:
    # Skip header
    next(f)
    for line in f:
        # Find all JSON arrays in the line
        # Pattern: " [...]" 
        matches = re.findall(r'"\[({.*?})\]"', line)
        
        for i, match in enumerate(matches):
            try:
                # Reconstruct the JSON array
                json_str = '[' + match + ']'
                data = json.loads(json_str)
                
                for item in data:
                    cmd = item.get('cmd', 'Unknown')
                    
                    # First match = CPU processes
                    if i == 0 and 'cpu' in item:
                        cpu_totals[cmd] += float(item['cpu'])
                        cpu_counts[cmd] += 1
                    
                    # Second match = Memory processes  
                    elif i == 1 and 'rss_mb' in item:
                        mem_totals[cmd] += int(item['rss_mb'])
                        mem_counts[cmd] += 1
            except json.JSONDecodeError:
                continue

# Print CPU results
print("\033[1;31mTOP PROCESSES BY CPU AVERAGE\033[0m")
print("Process name appears with weighted CPU usage in logs\n")

sorted_cpu = sorted(cpu_totals.items(), key=lambda x: x[1], reverse=True)[:15]
for cmd, total in sorted_cpu:
    avg = total / cpu_counts[cmd] if cpu_counts[cmd] > 0 else 0
    print(f"{total:8.2f}  {cmd} (avg: {avg:.2f}%)")

print()
print("\033[1;31mTOP PROCESSES BY MEMORY AVERAGE\033[0m\n")

sorted_mem = sorted(mem_totals.items(), key=lambda x: x[1], reverse=True)[:15]
for cmd, total in sorted_mem:
    avg = total // mem_counts[cmd] if mem_counts[cmd] > 0 else 0
    print(f"{total:10d} MB  {cmd} (avg: {avg:d} MB)")
PYTHON_SCRIPT
    
    echo ""
}

show_trends() {
    local file=$1
    local metric=${2:-"cpu"}
    local interval=${3:-"hourly"}  # hourly, daily
    
    echo -e "${BOLD}${CYAN}=== ${metric^^} Trends ===${NC}"
    echo -e "${YELLOW}Interval: ${interval}${NC}"
    echo ""
    
    local column values title
    
    case "$metric" in
        cpu)
            column=2
            title="CPU Usage (%)"
            ;;
        memory|mem)
            column=9
            title="Memory Used (MB)"
            ;;
        disk)
            column=17
            title="Disk Usage (%)"
            ;;
        network|net)
            column=18
            title="Network In (MB)"
            ;;
        *)
            echo "Unknown metric: $metric" >&2
            return 1
            ;;
    esac
    
    # Get values and timestamps
    case "$interval" in
        hourly)
            # Average by hour
            values=$(tail -n +2 "$file" | awk -F, -v col="$column" '
                {
                    split($1, ts, "T")
                    hour = substr(ts[2], 1, 2)
                    key = ts[1] " " hour ":00"
                    sum[key] += $col
                    count[key]++
                }
                END {
                    for (k in sum) {
                        printf "%s %d\n", k, sum[k]/count[k]
                    }
                }' | sort | awk '{print $4}')
            ;;
        daily)
            # Average by day
            values=$(tail -n +2 "$file" | awk -F, -v col="$column" '
                {
                    split($1, ts, "T")
                    key = ts[1]
                    sum[key] += $col
                    count[key]++
                }
                END {
                    for (k in sum) {
                        printf "%s %d\n", k, sum[k]/count[k]
                    }
                }' | sort | awk '{print $2}')
            ;;
        *)
            # Raw values (last 30)
            values=$(tail -n +2 "$file" | tail -30 | cut -d, -f"$column")
            ;;
    esac
    
    draw_ascii_chart "$title" "$values" 40
}

show_recent() {
    local file=$1
    local count=${2:-10}
    
    echo -e "${BOLD}${CYAN}=== Most Recent ${count} Samples ===${NC}"
    echo ""
    
    # Format and display recent data
    # Columns: 1=timestamp, 2=total_cpu, 9=used_mem_mb, 17=disk_usage, 18=net_in_mb
    {
        echo "Timestamp,CPU%,Mem MB,Disk%,Net In MB"
        tail -n +2 "$file" | tail -"$count" | awk -F, '{
            printf "%s,%.1f,%d,%.1f,%d\n", $1, $2, $9, $17, $18
        }'
    } | column -t -s,
    
    echo ""
}

show_help() {
    cat <<EOF
Mac Metrics Analyzer - View and analyze historical metrics

Usage: mac-analyze.sh [command] [options]

Commands:
  summary [today|yesterday|week|month]  Show summary statistics
  recent [N]                            Show last N samples (default: 10)
  offenders [hours]                     Show top resource consumers
  trends [metric] [interval]            Show trends for a metric
                                        Metrics: cpu, memory, disk, network
                                        Intervals: hourly, daily
  files                                 List available CSV log files
  watch                                 Live monitoring (refresh every 5 sec)
  help                                  Show this help message

Examples:
  mac-analyze.sh summary today
  mac-analyze.sh offenders 48
  mac-analyze.sh trends cpu hourly
  mac-analyze.sh recent 20
EOF
}

watch_live() {
    # Live monitoring with refresh
    local refresh_rate=${1:-5}
    
    while true; do
        clear
        ~/scripts/mac-monitor.sh
        sleep "$refresh_rate"
    done
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    local command=${1:-"summary"}
    local file
    
    # Get the CSV file to analyze
    case "$command" in
        files)
            echo -e "${BOLD}${CYAN}Available CSV Log Files:${NC}"
            get_csv_files | while read -r f; do
                local size samples
                size=$(ls -lh "$f" | awk '{print $5}')
                samples=$(tail -n +2 "$f" | wc -l | tr -d ' ')
                echo "  $(basename "$f")  (${size}, ${samples} samples)"
            done
            return 0
            ;;
        help|--help|-h)
            show_help
            return 0
            ;;
        watch)
            watch_live "${2:-5}"
            return 0
            ;;
    esac
    
    # For other commands, we need a CSV file
    file=$(get_latest_csv)
    
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}No CSV log files found in ${LOG_DIR}${NC}"
        echo -e "Run the monitor script first: ~/scripts/mac-monitor.sh"
        exit 1
    fi
    
    case "$command" in
        summary)
            show_summary "$file" "${2:-all}"
            ;;
        recent)
            show_recent "$file" "${2:-10}"
            ;;
        offenders)
            show_top_offenders "$file" "${2:-24}"
            ;;
        trends)
            show_trends "$file" "${2:-cpu}" "${3:-hourly}"
            ;;
        *)
            echo "Unknown command: $command"
            echo "Run 'mac-analyze.sh help' for usage information"
            exit 1
            ;;
    esac
}

# Run main function
main "${@}"