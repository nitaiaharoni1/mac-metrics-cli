#!/bin/bash

# Mac Metrics Cleanup Script - Remove data older than 30 days

set -e

# Configuration
LOG_DIR="${HOME}/logs/mac-metrics"
RETENTION_DAYS=30

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

echo -e "${BOLD}${CYAN}=== Mac Metrics Cleanup ===${NC}"
echo "Keeping data for the last ${RETENTION_DAYS} days"
echo ""

# Check if log directory exists
if [[ ! -d "$LOG_DIR" ]]; then
    echo -e "${YELLOW}Log directory does not exist: $LOG_DIR${NC}"
    exit 0
fi

cd "$LOG_DIR"

# Find and remove CSV files older than retention period
echo -e "${BOLD}Checking for old CSV files...${NC}"
cleanup_count=0
space_freed=0

# Current time minus retention days
cutoff_date=$(date -v-${RETENTION_DAYS}d +"%Y%m")

for csv_file in *.csv; do
    [[ -f "$csv_file" ]] || continue
    
    # Extract year and month from filename (format: YYYY-MM.csv)
    file_month=$(basename "$csv_file" .csv | sed 's/-//g')
    
    # Check if file is older than cutoff
    if [[ "$file_month" < "$cutoff_date" ]]; then
        # Get file size before deletion
        file_size=$(du -k "$csv_file" | cut -f1)
        
        # Calculate approximate age
        current_month=$(date +"%Y%m")
        years_diff=$(( (${current_month:0:4} - ${file_month:0:4}) * 12 ))
        months_diff=${current_month:4:2}
        month_diff=$((months_diff - ${file_month:4:2}))
        days_old=$(((years_diff + month_diff) * 30))
        
        echo -e "  ${RED}Removing${NC}: $csv_file (~$days_old days old, ${file_size}KB)"
        rm "$csv_file"
        ((cleanup_count++))
        ((space_freed += file_size))
    else
        echo -e "  ${GREEN}Keeping${NC}: $csv_file"
    fi
done

echo ""

# Clean up old log files (monitor.log and monitor-error.log)
echo -e "${BOLD}Cleaning up log files...${NC}"
for log_file in monitor.log monitor-error.log; do
    if [[ -f "$log_file" && -s "$log_file" ]]; then
        # Get file size in bytes, then convert to KB
        size_bytes=$(wc -c < "$log_file" 2>/dev/null || echo "0")
        size_kb=$((size_bytes / 1024))
        
        if [[ $size_kb -gt 1024 ]]; then
            echo -e "  ${YELLOW}Truncating${NC}: $log_file (${size_kb}KB -> keeping last 100KB)"
            tail -c 100k "$log_file" > "${log_file}.tmp"
            mv "${log_file}.tmp" "$log_file"
        else
            echo -e "  ${GREEN}Keeping${NC}: $log_file (${size_kb}KB)"
        fi
    fi
done

echo ""

# Summary
echo -e "${BOLD}Cleanup Summary:${NC}"
if [[ $cleanup_count -gt 0 ]]; then
    if [[ $space_freed -gt 1024 ]]; then
        space_display="$((space_freed / 1024))MB"
    else
        space_display="${space_freed}KB"
    fi
    echo -e "  Removed $cleanup_count old CSV file(s)"
    echo -e "  Freed: ${space_display}"
else
    echo -e "  ${GREEN}No old files to remove${NC}"
fi

echo ""

# List remaining files
echo -e "${BOLD}Current CSV files:${NC}"
csv_count=0
for csv_file in *.csv; do
    [[ -f "$csv_file" ]] || continue
    size=$(du -h "$csv_file" | cut -f1)
    samples=$(tail -n +2 "$csv_file" | wc -l | tr -d ' ')
    echo "  $(basename "$csv_file")   $size   ($samples samples)"
    ((csv_count++))
done

if [[ $csv_count -eq 0 ]]; then
    echo "  No CSV files yet"
fi

echo ""
echo -e "${CYAN}Cleanup will run automatically weekly.${NC}"
echo "Log location: $LOG_DIR"