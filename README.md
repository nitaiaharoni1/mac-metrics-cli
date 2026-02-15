# Mac Metrics CLI

Free, performant Mac performance monitoring tool that tracks system metrics over time with per-process attribution. Built with shell scripts - no dependencies required.

## Features

- **System Metrics**: CPU, memory, disk, network, temperature
- **Per-Process Attribution**: Identify which apps consume resources
- **Historical Tracking**: CSV logging for trend analysis
- **Automatic Monitoring**: Runs every 5 minutes via launchd
- **Startup Integration**: Auto-starts on Mac login
- **Data Retention**: Automatic cleanup (30-day retention)
- **Free & Lightweight**: Uses only macOS built-in tools

## Installation

### Via Homebrew (Recommended)

```bash
brew tap nitaiaharoni1/homebrew-tools
brew install mac-metrics-cli
```

### Manual Installation

```bash
# Clone the repo
git clone https://github.com/nitaiaharoni1/mac-metrics-cli.git
cd mac-metrics-cli

# Install scripts
chmod +x *.sh
cp *.sh ~/scripts/

# Set up automatic startup
launchctl load ~/Library/LaunchAgents/com.user.mac-monitor.plist
```

## Quick Start

```bash
# Check status
mac-monitor-status

# Start monitoring (one-time, interactive display)
mac-monitor

# View summary statistics
mac-analyze summary

# Identify resource hogs
mac-analyze offenders

# View live monitoring
mac-analyze watch
```

## Commands

### Monitoring

```bash
# Run monitor with live display
mac-monitor

# Run in daemon mode (log only)
mac-monitor --daemon

# JSON output
mac-monitor --json
```

### Analysis

```bash
# Summary statistics
mac-analyze summary

# View recent samples
mac-analyze recent 20

# Top resource consumers
mac-analyze offenders 48

# Historical trends
mac-analyze trends cpu hourly
mac-analyze trends memory daily
mac-analyze trends disk hourly
mac-analyze network hourly

# List available data files
mac-analyze files

# Live monitoring
mac-analyze watch
```

### Utilities

```bash
# Check system status
mac-monitor-status

# Run cleanup manually
mac-monitor-cleanup
```

## Data Storage

All metrics are stored in `~/logs/mac-metrics/`:

- **CSV Files**: `YYYY-MM.csv` (monthly rotation)
- **Monitor Logs**: `monitor.log`, `monitor-error.log`
- **Cleanup Logs**: `cleanup.log`, `cleanup-error.log`

### Data Retention

- CSV data: Last 30 days automatically removed (Sundays 3AM)
- Log files: Truncated at 1MB

## Automatic Monitoring

The tool includes launchd agents for automatic operation:

### Monitoring Agent

- **Name**: `com.user.mac-monitor`
- **Schedule**: Every 5 minutes
- **Startup**: Runs automatically on login
- **Location**: `~/Library/LaunchAgents/com.user.mac-monitor.plist`

### Cleanup Agent

- **Name**: `com.user.mac-monitor-cleanup`
- **Schedule**: Every Sunday at 3:00 AM
- **Retention**: Removes data older than 30 days
- **Location**: `~/Library/LaunchAgents/com.user.mac-monitor-cleanup.plist`

## Managing Automatic Monitoring

```bash
# Stop monitoring
launchctl unload ~/Library/LaunchAgents/com.user.mac-monitor.plist

# Start monitoring
launchctl load ~/Library/LaunchAgents/com.user.mac-monitor.plist

# Stop cleanup
launchctl unload ~/Library/LaunchAgents/com.user.mac-monitor-cleanup.plist

# Start cleanup
launchctl load ~/Library/LaunchAgents/com.user.mac-monitor-cleanup.plist
```

## System Requirements

- macOS 10.14 (Mojave) or later
- Bash (built-in with macOS)
- No external dependencies

## Metrics Tracked

### System Metrics

| Metric | Description |
|--------|-------------|
| CPU | Total, user, system, idle percentages |
| Memory | Used, free, swap, pressure level |
| Disk | Read/write throughput, I/O operations, usage % |
| Network | Total/recent in/out bytes, rate (KB/s) |
| Temperature | CPU and GPU temperatures (if available) |

### Per-Process Metrics

- **Top 10 by CPU**: PID, CPU %, RSS (MB), command name
- **Top 10 by Memory**: PID, RSS (MB), % memory, command name
- **Top 10 by Disk**: Open file count, command name

## Examples

### View CPU Trends Hourly

```bash
mac-analyze trends cpu hourly
```

### Find Memory Hogs Over 48 Hours

```bash
mac-analyze offenders 48
```

### Check System Status

```bash
mac-monitor-status
```

### Export to JSON

```bash
mac-monitor --json > metrics.json
```

## Performance Impact

- **CPU开销**: ~0.1% per sample
- **Sampling Rate**: Every 5 minutes (300 seconds)
- **Disk Space**: ~2-5KB per sample
- **Memory**: Negligible (script runs briefly)

## Troubleshooting

### Monitor not collecting data

```bash
# Check if agent is loaded
launchctl list | grep mac-monitor

# Check logs
tail -20 ~/logs/mac-metrics/monitor-error.log

# Manually trigger collection
launchctl kickstart -k gui/$(id -u)/com.user.mac-monitor
```

### Cleanup not running

```bash
# Check agent status
launchctl list | grep mac-monitor-cleanup

# Run cleanup manually
mac-monitor-cleanup
```

## License

MIT

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Author

Nitai Aharoni

## See Also

- [homebrew-tools](https://github.com/nitaiaharoni1/homebrew-tools) - Other CLI tools
- [Gmail CLI](https://github.com/nitaiaharoni1/gmail-cli) - Gmail command-line interface
- [Google Calendar CLI](https://github.com/nitaiaharoni1/google-calendar-cli) - Calendar management

## Acknowledgments

Inspired by the need for a free, lightweight Mac monitoring solution with per-process tracking.