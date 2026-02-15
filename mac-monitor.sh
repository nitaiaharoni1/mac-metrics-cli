#!/bin/bash

# Mac Metrics Monitor - System-wide metrics with per-process attribution
# Samples every run, logs to CSV, displays in terminal

set -euo pipefail

# Configuration
LOG_DIR="${HOME}/logs/mac-metrics"
CSV_FILE="${LOG_DIR}/$(date +%Y-%m).csv"
TOP_N=10  # Number of top processes to track

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# ============================================================================
# SYSTEM METRICS COLLECTION
# ============================================================================

get_cpu_usage() {
    # Get CPU usage from top (user + system)
    local cpu_output
    cpu_output=$(top -l 1 -n 0 -s 0 | grep "CPU usage")
    
    # Parse: CPU usage: 5.26% user, 10.52% sys, 84.21% idle
    local user_cpu sys_cpu idle_cpu
    user_cpu=$(echo "$cpu_output" | awk '{print $3}' | tr -d '%')
    sys_cpu=$(echo "$cpu_output" | awk '{print $5}' | tr -d '%')
    idle_cpu=$(echo "$cpu_output" | awk '{print $7}' | tr -d '%')
    
    local total_cpu
    total_cpu=$(echo "scale=2; 100 - $idle_cpu" | bc)
    
    echo "${total_cpu:-0},${user_cpu:-0},${sys_cpu:-0},${idle_cpu:-0}"
}

get_memory_info() {
    # Get memory info - use a more reliable approach
    local page_size=4096  # Default page size
    
    # Get total memory from sysctl first
    local total_mem
    total_mem=$(sysctl -n hw.memsize 2>/dev/null) || total_mem=$((24 * 1024 * 1024 * 1024))  # fallback 24GB
    total_mem=$((total_mem / 1024 / 1024))  # Convert to MB
    
    # Parse memory pages from vm_stat
    local pages_free pages_active pages_inactive pages_speculative pages_wired pages_compressed
    
    # Use awk to parse vm_stat in one pass (more reliable)
    read -r pages_free pages_active pages_inactive pages_speculative pages_wired pages_compressed < <(
        vm_stat 2>/dev/null | awk '
            /Pages free:/ { free = $3; gsub(/\./, "", free) }
            /Pages active:/ { active = $3; gsub(/\./, "", active) }
            /Pages inactive:/ { inactive = $3; gsub(/\./, "", inactive) }
            /Pages speculative:/ { spec = $3; gsub(/\./, "", spec) }
            /Pages wired down:/ { wired = $4; gsub(/\./, "", wired) }
            /Pages occupied by compressor:/ { comp = $5; gsub(/\./, "", comp) }
            END { print free+0, active+0, inactive+0, spec+0, wired+0, comp+0 }
        '
    )
    
    # Set defaults if parsing failed
    pages_free=${pages_free:-0}
    pages_active=${pages_active:-0}
    pages_inactive=${pages_inactive:-0}
    pages_speculative=${pages_speculative:-0}
    pages_wired=${pages_wired:-0}
    pages_compressed=${pages_compressed:-0}
    
    # Calculate used memory (active + wired + compressed)
    local used_mb free_mb
    used_mb=$(( ( (pages_active + pages_wired + pages_compressed) * page_size / 1024 / 1024) ))
    free_mb=$(( ( (pages_free + pages_inactive + pages_speculative) * page_size / 1024 / 1024) ))
    
    # Get swap usage using sysctl
    local swap_used_mb swap_total_mb
    swap_used_mb=$(sysctl -n vm.swapused 2>/dev/null | awk '{printf "%d", $1/1024/1024}' || echo "0")
    swap_total_mb=$(sysctl -n vm.swaptotal 2>/dev/null | awk '{printf "%d", $1/1024/1024}' || echo "0")
    
    # Memory pressure (system may not have this command)
    local pressure
    pressure=$(memory_pressure 2>/dev/null | head -1 || echo "Normal")
    case "$pressure" in
        *"Nominal"*) pressure="Normal" ;;
        *"Warning"*) pressure="Warning" ;;
        *"Critical"*) pressure="Critical" ;;
        *) pressure="Normal" ;;
    esac
    
    echo "${total_mem},${used_mb},${free_mb},${swap_used_mb},${swap_total_mb},${pressure}"
}

get_disk_io() {
    # Get disk I/O stats from iostat
    # Format: disk0 KB/t tps MB/s disk4 KB/t tps MB/s ...
    local disk_stats
    disk_stats=$(iostat -d -c 2 2>/dev/null | tail -1)
    
    # Sum all disk activity (MB/s columns are at positions 3, 6, 9, etc.)
    # tps columns are at positions 2, 5, 8, etc.
    local total_mbs total_tps
    total_mbs=$(echo "$disk_stats" | awk '{
        for(i=3; i<=NF; i+=3) {
            sum += $i
        }
        printf "%.2f", sum
    }')
    total_tps=$(echo "$disk_stats" | awk '{
        for(i=2; i<=NF; i+=3) {
            sum += $i
        }
        printf "%d", sum
    }')
    
    # Get disk capacity
    local disk_usage
    disk_usage=$(df -h / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    
    # Convert MB/s to KB/s for consistency
    local kbs_read kbs_write
    kbs_read=$(echo "$total_mbs" | awk '{printf "%.0f", $1 * 1024 / 2}')  # Approximate half as read
    kbs_write=$(echo "$total_mbs" | awk '{printf "%.0f", $1 * 1024 / 2}') # Approximate half as write
    
    echo "${kbs_read:-0},${kbs_write:-0},${total_tps:-0},${disk_usage:-0}"
}

get_network_io() {
    # Get network bytes from netstat
    local net_stats total_in total_out
    net_stats=$(netstat -ib | grep -E "en0|en1" | head -1)
    
    if [[ -n "$net_stats" ]]; then
        total_in=$(echo "$net_stats" | awk '{print $7}')
        total_out=$(echo "$net_stats" | awk '{print $10}')
        
        # Convert to human readable (MB)
        total_in=$((total_in / 1024 / 1024))
        total_out=$((total_out / 1024 / 1024))
    else
        total_in=0
        total_out=0
    fi
    
    # Get current session stats (delta from last check if file exists)
    local prev_file="${LOG_DIR}/.prev_network"
    local rate_in rate_out
    rate_in=0
    rate_out=0
    
    if [[ -f "$prev_file" ]]; then
        local prev_in prev_out prev_time
        read -r prev_time prev_in prev_out < "$prev_file"
        local curr_time
        curr_time=$(date +%s)
        local delta_time=$((curr_time - prev_time))
        
        if [[ $delta_time -gt 0 ]]; then
            rate_in=$(( ( (total_in - prev_in) * 1024 ) / delta_time ))  # KB/s
            rate_out=$(( ( (total_out - prev_out) * 1024 ) / delta_time ))  # KB/s
        fi
    fi
    
    # Store current values for next calculation
    echo "$(date +%s) ${total_in} ${total_out}" > "$prev_file"
    
    echo "${total_in},${total_out},${rate_in},${rate_out}"
}

get_temperature() {
    # Try to get temperature from various sources
    local temp_cpu temp_gpu
    
    # Method 1: osx-cpu-temp (if installed via brew)
    if command -v osx-cpu-temp &> /dev/null; then
        temp_cpu=$(osx-cpu-temp 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0")
    # Method 2: powermetrics (requires sudo, try without password prompt)
    elif [[ -x /usr/bin/powermetrics ]]; then
        local power_out
        power_out=$(/usr/bin/powermetrics --samplers smc -i 1 -n 1 2>/dev/null || echo "")
        temp_cpu=$(echo "$power_out" | grep -i "cpu die temperature" | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0")
        temp_gpu=$(echo "$power_out" | grep -i "gpu die temperature" | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0")
    else
        temp_cpu="0"
        temp_gpu="0"
    fi
    
    echo "${temp_cpu:-0},${temp_gpu:-0}"
}

# ============================================================================
# PER-PROCESS ATTRIBUTION
# ============================================================================

get_top_processes_cpu() {
    # Get top N processes by CPU usage
    local processes
    processes=$(ps -arcwwwxo "pid,%cpu,rss,command" | head -n $((TOP_N + 1)) | tail -n "$TOP_N")
    
    # Format as JSON array
    local json="["
    local first=true
    
    while IFS= read -r line; do
        local pid cpu rss cmd
        pid=$(echo "$line" | awk '{print $1}')
        cpu=$(echo "$line" | awk '{print $2}')
        rss=$(echo "$line" | awk '{print $3}')
        cmd=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
        
        # Escape special characters in command name
        cmd=$(echo "$cmd" | sed 's/"/\\"/g')
        
        if [[ "$first" == true ]]; then
            first=false
        else
            json+=","
        fi
        
        json+="{\"pid\":${pid},\"cpu\":${cpu},\"rss_mb\":$((rss/1024)),\"cmd\":\"${cmd}\"}"
    done <<< "$processes"
    
    json+="]"
    echo "$json"
}

get_top_processes_memory() {
    # Get top N processes by memory usage (RSS)
    local processes
    processes=$(ps -amcwwwxo "pid,rss,%mem,command" | head -n $((TOP_N + 1)) | tail -n "$TOP_N")
    
    # Format as JSON array
    local json="["
    local first=true
    
    while IFS= read -r line; do
        local pid rss mem_pct cmd
        pid=$(echo "$line" | awk '{print $1}')
        rss=$(echo "$line" | awk '{print $2}')
        mem_pct=$(echo "$line" | awk '{print $3}')
        cmd=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
        
        # Escape special characters in command name
        cmd=$(echo "$cmd" | sed 's/"/\\"/g')
        
        if [[ "$first" == true ]]; then
            first=false
        else
            json+=","
        fi
        
        json+="{\"pid\":${pid},\"rss_mb\":$((rss/1024)),\"mem_pct\":${mem_pct},\"cmd\":\"${cmd}\"}"
    done <<< "$processes"
    
    json+="]"
    echo "$json"
}

get_top_processes_disk() {
    # macOS doesn't have iotop like Linux, but we can use fs_usage (requires sudo)
    # Alternative: track processes with open files using lsof
    local processes
    processes=$(lsof 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -n "$TOP_N")
    
    # Format as JSON array (count of open files as proxy for disk activity)
    local json="["
    local first=true
    
    while IFS= read -r line; do
        local count cmd
        count=$(echo "$line" | awk '{print $1}')
        cmd=$(echo "$line" | awk '{print $2}')
        
        # Escape special characters
        cmd=$(echo "$cmd" | sed 's/"/\\"/g')
        
        if [[ -z "$cmd" ]]; then
            continue
        fi
        
        if [[ "$first" == true ]]; then
            first=false
        else
            json+=","
        fi
        
        json+="{\"open_files\":${count},\"cmd\":\"${cmd}\"}"
    done <<< "$processes"
    
    json+="]"
    echo "$json"
}

# ============================================================================
# OUTPUT FUNCTIONS
# ============================================================================

draw_ascii_bar() {
    local value=$1
    local max=$2
    local width=${3:-40}
    
    local filled=$(( (value * width) / max ))
    local empty=$((width - filled))
    
    local bar="["
    for ((i=0; i<filled; i++)); do bar+="="; done
    for ((i=0; i<empty; i++)); do bar+=" "; done
    bar+="]"
    
    echo "$bar"
}

print_terminal_output() {
    local timestamp=$1
    local cpu_data=$2
    local mem_data=$3
    local disk_data=$4
    local net_data=$5
    local temp_data=$6
    local top_cpu=$7
    local top_mem=$8
    
    # Parse CPU data
    IFS=',' read -r total_cpu user_cpu sys_cpu idle_cpu <<< "$cpu_data"
    
    # Parse Memory data
    IFS=',' read -r total_mem used_mem free_mem swap_used swap_total pressure <<< "$mem_data"
    
    # Parse Disk data
    IFS=',' read -r disk_read disk_write tps disk_usage <<< "$disk_data"
    
    # Parse Network data
    IFS=',' read -r net_in net_out rate_in rate_out <<< "$net_data"
    
    # Parse Temperature
    IFS=',' read -r temp_cpu temp_gpu <<< "$temp_data"
    
    clear
    echo -e "${BOLD}${CYAN}=== Mac Metrics Monitor ===${NC}"
    echo -e "${YELLOW}Timestamp:${NC} ${timestamp}"
    echo ""
    
    # CPU Section
    echo -e "${BOLD}${GREEN}CPU USAGE${NC}"
    echo -e "Total:   $(draw_ascii_bar "${total_cpu%.*}" 100 30) ${total_cpu}%"
    echo -e "  User:  ${user_cpu}%  |  System: ${sys_cpu}%"
    if [[ "$temp_cpu" != "0" ]]; then
        echo -e "  Temp:  ${temp_cpu} C"
    fi
    echo ""
    
    # Memory Section
    echo -e "${BOLD}${GREEN}MEMORY${NC}"
    echo -e "Used:    $(draw_ascii_bar "${used_mem}" "${total_mem}" 30) ${used_mem}/${total_mem} MB"
    echo -e "  Pressure: ${pressure}"
    echo -e "  Swap:   ${swap_used}/${swap_total} MB"
    echo ""
    
    # Disk Section
    echo -e "${BOLD}${GREEN}DISK${NC}"
    echo -e "Usage:   $(draw_ascii_bar "${disk_usage}" 100 30) ${disk_usage}%"
    echo -e "  Read:  ${disk_read} KB/s  |  Write: ${disk_write} KB/s"
    echo ""
    
    # Network Section
    echo -e "${BOLD}${GREEN}NETWORK${NC}"
    echo -e "Total:   In: ${net_in} MB  |  Out: ${net_out} MB"
    echo -e "  Rate:  In: ${rate_in} KB/s  |  Out: ${rate_out} KB/s"
    echo ""
    
    # Top Processes by CPU
    echo -e "${BOLD}${RED}TOP ${TOP_N} PROCESSES BY CPU${NC}"
    printf "%-8s %6s %8s %s\n" "PID" "CPU%" "RSS(MB)" "COMMAND"
    
    # Parse and display top CPU processes
    echo "$top_cpu" | sed 's/\[{//' | sed 's/}\]//' | sed 's/},{/}\n{/g' | while IFS= read -r proc; do
        [[ -z "$proc" ]] && continue
        local pid cpu rss cmd
        pid=$(echo "$proc" | grep -o '"pid":[0-9]*' | cut -d: -f2)
        cpu=$(echo "$proc" | grep -o '"cpu":[0-9.]*' | cut -d: -f2)
        rss=$(echo "$proc" | grep -o '"rss_mb":[0-9]*' | cut -d: -f2)
        cmd=$(echo "$proc" | grep -o '"cmd":"[^"]*"' | cut -d\" -f4)
        printf "%-8s %6s %8s %s\n" "$pid" "${cpu}%" "$rss" "${cmd:0:50}"
    done
    echo ""
    
    # Top Processes by Memory
    echo -e "${BOLD}${RED}TOP ${TOP_N} PROCESSES BY MEMORY${NC}"
    printf "%-8s %8s %6s %s\n" "PID" "RSS(MB)" "MEM%" "COMMAND"
    
    # Parse and display top Memory processes
    echo "$top_mem" | sed 's/\[{//' | sed 's/}\]//' | sed 's/},{/}\n{/g' | while IFS= read -r proc; do
        [[ -z "$proc" ]] && continue
        local pid rss mem_pct cmd
        pid=$(echo "$proc" | grep -o '"pid":[0-9]*' | cut -d: -f2)
        rss=$(echo "$proc" | grep -o '"rss_mb":[0-9]*' | cut -d: -f2)
        mem_pct=$(echo "$proc" | grep -o '"mem_pct":[0-9.]*' | cut -d: -f2)
        cmd=$(echo "$proc" | grep -o '"cmd":"[^"]*"' | cut -d\" -f4)
        printf "%-8s %8s %6s %s\n" "$pid" "$rss" "${mem_pct}%" "${cmd:0:50}"
    done
}

write_to_csv() {
    local timestamp=$1
    local cpu_data=$2
    local mem_data=$3
    local disk_data=$4
    local net_data=$5
    local temp_data=$6
    local top_cpu=$7
    local top_mem=$8
    local top_disk=$9
    
    # Create CSV with header if file doesn't exist
    if [[ ! -f "$CSV_FILE" ]]; then
        echo "timestamp,total_cpu,user_cpu,sys_cpu,idle_cpu,cpu_temp,gpu_temp,total_mem_mb,used_mem_mb,free_mem_mb,swap_used_mb,swap_total_mb,mem_pressure,disk_read_kbs,disk_write_kbs,disk_tps,disk_usage_pct,net_in_mb,net_out_mb,net_rate_in_kbs,net_rate_out_kbs,top_cpu_procs,top_mem_procs,top_disk_procs" > "$CSV_FILE"
    fi
    
    # Write data row
    echo "${timestamp},${cpu_data},${temp_data},${mem_data},${disk_data},${net_data},\"${top_cpu}\",\"${top_mem}\",\"${top_disk}\"" >> "$CSV_FILE"
}

# ============================================================================
# AGENT MANAGEMENT
# ============================================================================

install_agents() {
    echo -e "${BOLD}${CYAN}=== Installing Mac Metrics Monitor LaunchAgents ===${NC}"
    echo ""
    
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local launch_agents_dir="${HOME}/Library/LaunchAgents"
    
    # Create LaunchAgents directory if it doesn't exist
    mkdir -p "$launch_agents_dir"
    
    # Create monitor launchd agent
    local monitor_agent="${launch_agents_dir}/com.user.mac-monitor.plist"
    echo "Creating monitor agent: $monitor_agent"
    
    cat > "$monitor_agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.mac-monitor</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${script_dir}/mac-monitor.sh</string>
        <string>--daemon</string>
    </array>
    
    <key>StartInterval</key>
    <integer>300</integer>
    
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/monitor.log</string>
    
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/monitor-error.log</string>
    
    <key>RunAtLoad</key>
    <true/>
    
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF
    
    # Create cleanup launchd agent
    local cleanup_agent="${launch_agents_dir}/com.user.mac-monitor-cleanup.plist"
    echo "Creating cleanup agent: $cleanup_agent"
    
    cat > "$cleanup_agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.mac-monitor-cleanup</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${script_dir}/mac-monitor-cleanup.sh</string>
    </array>
    
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>0</integer>
        <key>Hour</key>
        <integer>3</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/cleanup.log</string>
    
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/cleanup-error.log</string>
    
    <key>RunAtLoad</key>
    <false/>
    
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF
    
    echo ""
    echo -e "${GREEN}LaunchAgents installed!${NC}"
    echo ""
    echo "Now load the agents:"
    echo "  launchctl load ${monitor_agent}"
    echo "  launchctl load ${cleanup_agent}"
    echo ""
    echo "Or use: mac-monitor start"
}

show_help() {
    cat <<EOF
Mac Metrics Monitor - Track system performance over time

Usage: mac-monitor [command]

Commands:
  (no args)      Run monitor with live display and log to CSV
  --daemon       Run in background (log only, no display)
  --json         Output metrics as JSON
  install-agent  Configure automatic monitoring via launchd
  start          Start automatic monitoring
  stop           Stop automatic monitoring
  status         Show current status
  help           Show this help message

Examples:
  mac-monitor                 # One-time monitoring
  mac-monitor --daemon        # Background collection
  mac-monitor install-agent   # Set up auto-monitoring
  mac-monitor start           # Begin auto-monitoring

Data is stored in: ~/logs/mac-metrics/
EOF
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Handle special commands
    case "${1:-}" in
        install-agent)
            install_agents
            return 0
            ;;
        start)
            local launch_agents_dir="${HOME}/Library/LaunchAgents"
            echo "Starting monitor agent..."
            launchctl load "${launch_agents_dir}/com.user.mac-monitor.plist"
            echo "Starting cleanup agent..."
            launchctl load "${launch_agents_dir}/com.user.mac-monitor-cleanup.plist"
            echo "Done! Monitoring will run every 5 minutes."
            return 0
            ;;
        stop)
            local launch_agents_dir="${HOME}/Library/LaunchAgents"
            echo "Stopping monitor agent..."
            launchctl unload "${launch_agents_dir}/com.user.mac-monitor.plist" 2>/dev/null || echo "Monitor agent not running"
            echo "Stopping cleanup agent..."
            launchctl unload "${launch_agents_dir}/com.user.mac-monitor-cleanup.plist" 2>/dev/null || echo "Cleanup agent not running"
            echo "Done!"
            return 0
            ;;
        status)
            echo "=== Mac Metrics Monitor Status ==="
            echo ""
            # Use exact match to avoid matching cleanup agent
            if launchctl list | grep -E "^[0-9]+\s+[0-9]+\s+com\.user\.mac-monitor$" > /dev/null 2>&1; then
                echo "Monitor agent: RUNNING"
                launchctl list | grep -E "com\.user\.mac-monitor$"
            else
                echo "Monitor agent: NOT RUNNING"
            fi
            
            echo ""
            if launchctl list | grep "com.user.mac-monitor-cleanup" > /dev/null 2>&1; then
                echo "Cleanup agent: RUNNING"
            else
                echo "Cleanup agent: NOT RUNNING"
            fi
            
            echo ""
            echo "Data location: ${LOG_DIR}"
            ls -lh "$LOG_DIR"/*.csv 2>/dev/null | awk '{print "  " $9 "   (" $5 ")"}'
            return 0
            ;;
        help|--help|-h)
            show_help
            return 0
            ;;
    esac
    
    # Original monitoring logic - run metrics collection
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Collect all metrics
    echo "Collecting metrics..." >&2
    
    local cpu_data mem_data disk_data net_data temp_data
    cpu_data=$(get_cpu_usage)
    mem_data=$(get_memory_info)
    disk_data=$(get_disk_io)
    net_data=$(get_network_io)
    temp_data=$(get_temperature)
    
    local top_cpu top_mem top_disk
    top_cpu=$(get_top_processes_cpu)
    top_mem=$(get_top_processes_memory)
    top_disk=$(get_top_processes_disk)
    
    # Output based on mode
    if [[ "${1:-}" == "--daemon" ]]; then
        # Daemon mode: just write to CSV
        write_to_csv "$timestamp" "$cpu_data" "$mem_data" "$disk_data" \
                     "$net_data" "$temp_data" "$top_cpu" "$top_mem" "$top_disk"
    elif [[ "${1:-}" == "--json" ]]; then
        # JSON output mode
        cat <<EOF
{
  "timestamp": "${timestamp}",
  "cpu": {
    "total": ${cpu_data%%,*},
    "user": $(echo "$cpu_data" | cut -d, -f2),
    "system": $(echo "$cpu_data" | cut -d, -f3),
    "idle": $(echo "$cpu_data" | cut -d, -f4),
    "temperature": $(echo "$temp_data" | cut -d, -f1)
  },
  "memory": {
    "total_mb": $(echo "$mem_data" | cut -d, -f1),
    "used_mb": $(echo "$mem_data" | cut -d, -f2),
    "free_mb": $(echo "$mem_data" | cut -d, -f3),
    "swap_used_mb": $(echo "$mem_data" | cut -d, -f4),
    "pressure": "$(echo "$mem_data" | cut -d, -f6)"
  },
  "disk": {
    "read_kbs": $(echo "$disk_data" | cut -d, -f1),
    "write_kbs": $(echo "$disk_data" | cut -d, -f2),
    "usage_pct": $(echo "$disk_data" | cut -d, -f4)
  },
  "network": {
    "in_mb": $(echo "$net_data" | cut -d, -f1),
    "out_mb": $(echo "$net_data" | cut -d, -f2),
    "rate_in_kbs": $(echo "$net_data" | cut -d, -f3),
    "rate_out_kbs": $(echo "$net_data" | cut -d, -f4)
  },
  "top_cpu_processes": ${top_cpu},
  "top_memory_processes": ${top_mem},
  "top_disk_processes": ${top_disk}
}
EOF
    else
        # Interactive mode: display terminal + write to CSV
        print_terminal_output "$timestamp" "$cpu_data" "$mem_data" "$disk_data" \
                              "$net_data" "$temp_data" "$top_cpu" "$top_mem"
        echo ""
        echo -e "${CYAN}Logging to: ${CSV_FILE}${NC}"
        write_to_csv "$timestamp" "$cpu_data" "$mem_data" "$disk_data" \
                     "$net_data" "$temp_data" "$top_cpu" "$top_mem" "$top_disk"
    fi
}

# Run main function
main "${@:-}"