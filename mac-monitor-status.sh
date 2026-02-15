#!/bin/bash

# Mac Monitor Status Check - Verify everything is running

set -euo pipefail

echo "=== Mac Metrics Monitor Status ==="
echo ""

# Check if launchd agent is loaded
if launchctl list | grep -q com.user.mac-monitor; then
    echo "Launchd Agent: RUNNING ✓"
    launchctl list | grep mac-monitor
else
    echo "Launchd Agent: NOT RUNNING ✗"
    echo "  To load: launchctl load ~/Library/LaunchAgents/com.user.mac-monitor.plist"
fi

echo ""

# Check if process is running
if pgrep -f "mac-monitor.sh --daemon" > /dev/null 2>&1; then
    echo "Monitor Process: RUNNING ✓"
    pgrep -f "mac-monitor.sh --daemon" | wc -l | xargs -I {} echo "  {} active instance(s)"
else
    echo "Monitor Process: NOT RUNNING (interval mode - this is normal) ✓"
fi

echo ""

# Check logs
if [[ -d ~/logs/mac-metrics ]]; then
    echo "Log Directory: EXISTS ✓"
    ls -la ~/logs/mac-metrics/ 2>/dev/null | tail -n +2
else
    echo "Log Directory: NOT FOUND ✗"
fi

echo ""

# Check CSV files
if [[ -f ~/logs/mac-metrics/*.csv ]]; then
    echo "CSV Data: EXISTS ✓"
    for file in ~/logs/mac-metrics/*.csv; do
        if [[ -f "$file" ]]; then
            samples=$(wc -l < "$file" | tr -d ' ')
            echo "  $(basename "$file"): $samples samples ($(du -h "$file" | cut -f1))"
        fi
    done
else
    echo "CSV Data: NOT FOUND (will be created on first run)"
fi

echo ""

# Show latest statistics
if [[ -d ~/scripts ]]; then
    echo "=== Quick Summary ==="
    ~/scripts/mac-analyze.sh summary 2>/dev/null || echo "  No data yet"
fi

echo ""
echo "=== Quick Commands ==="
echo "  View live: ~/scripts/mac-analyze.sh watch"
echo "  Summarize: ~/scripts/mac-analyze.sh summary"
echo "  Offenders: ~/scripts/mac-analyze.sh offenders"
echo "  Stop:      launchctl unload ~/Library/LaunchAgents/com.user.mac-monitor.plist"
echo "  Start:     launchctl load ~/Library/LaunchAgents/com.user.mac-monitor.plist"