# Network Performance Monitor

A Windows-based network performance monitoring tool with a PowerShell GUI for data collection and a standalone HTML dashboard for analysis.

## Overview

Monitor network availability and throughput from any Windows client. The tool continuously pings configurable targets and runs bidirectional TCP/UDP iperf3 bandwidth tests, storing all results in a local SQLite database. The HTML dashboard loads the database file directly in the browser for visualization — no server required.

## Features

### Data Collection (PowerShell)
- **Ping Monitoring**: Continuous availability checks against up to 3 targets
- **iperf3 Bandwidth Tests**: TCP and UDP tests in both directions (Upload + Download)
- **iperf-aware Ping Tagging**: Pings recorded during iperf tests are flagged (`during_iperf`) so you can filter them out for clean latency data
- **Configurable**: All parameters (targets, intervals, duration, bitrate) adjustable via GUI
- **SQLite Storage**: WAL mode for concurrent read/write, automatic schema migrations
- **Non-blocking Architecture**: Pings run in a separate Runspace, iperf tests in Background Jobs

### Dashboard (HTML)
- **Browser-only**: Loads `.db` files via WebAssembly (sql.js) — no upload, no server
- **Network Health Score**: 0–100 composite score based on availability, latency, jitter, packet loss, retransmits
- **SVG Charts**: Latency timeline, availability over time (5-min buckets), bandwidth, jitter, packet loss, retransmits, per-target availability donuts
- **Filtering**: By session, target, status, latency threshold, protocol, direction, iperf overlap
- **CSV Export**: Ping and iperf data to clipboard
- **Session Management**: Delete individual or all sessions
- **Dark/Light Mode**: Adapts to system preference

## Requirements

- Windows with PowerShell 5.1+
- [PSSQLite](https://github.com/RamblingCookieMonster/PSSQLite) module: `Install-Module PSSQLite`
- [iperf3 for Windows](https://iperf.fr/iperf-download.php)
- An iperf3 server running on the target: `iperf3 -s`

## Quick Start

1. Start the iperf3 server on the target machine:
   ```bash
   iperf3 -s
   ```

2. Run the monitor on the Windows client:
   ```powershell
   .\NetworkMonitor.ps1
   ```

3. Configure targets and settings in the GUI, then click Start.

4. After the measurement completes, open `dashboard.html` in any browser and load the `.db` file.

## GUI Settings

| Setting | Description | Default |
|---|---|---|
| Ping Targets | Comma-separated IPs/hostnames | 8.8.8.8, 1.1.1.1 |
| Ping Interval | Seconds between pings | 1 |
| iperf Server | iperf3 server IP/hostname | 192.168.1.1 |
| iperf Port | Server port | 5201 |
| iperf Interval | Minutes between test cycles | 5 |
| iperf Duration | Duration per single test (seconds) | 10 |
| UDP Bitrate | Target bitrate for UDP tests (Mbit/s) | 5 |
| Total Duration | Total measurement time (minutes, up to 1440) | 10 |

## Measurement Cycle

Each iperf cycle runs 4 tests:

1. TCP Upload (Client → Server)
2. TCP Download (Server → Client, `-R` flag)
3. UDP Upload
4. UDP Download

Pings continue during iperf tests but are tagged with `during_iperf=1` so they can be filtered in the dashboard.

## Database Schema

### `ping`
| Column | Type | Description |
|---|---|---|
| timestamp | TEXT | ISO timestamp |
| session_id | TEXT | Session identifier |
| target | TEXT | Ping target |
| status | TEXT | OK or FAIL |
| latency_ms | REAL | Response time (ms) |
| ttl | INTEGER | Time to Live |
| during_iperf | INTEGER | 1 if recorded during an iperf test |

### `iperf`
| Column | Type | Description |
|---|---|---|
| timestamp | TEXT | ISO timestamp |
| session_id | TEXT | Session identifier |
| target | TEXT | iperf server |
| protocol | TEXT | TCP or UDP |
| direction | TEXT | Upload or Download |
| bandwidth_mbps | REAL | Bandwidth (Mbit/s) |
| jitter_ms | REAL | Jitter in ms (UDP only) |
| packet_loss_pct | REAL | Packet loss % (UDP only) |
| retransmits | INTEGER | TCP retransmits |
| cpu_pct | REAL | CPU utilization % |

### `sessions`
| Column | Type | Description |
|---|---|---|
| session_id | TEXT | Unique session ID |
| start_time | TEXT | Start time |
| end_time | TEXT | End time |
| duration_minutes | INTEGER | Planned duration |
| ping_targets | TEXT | Ping targets |
| iperf_target | TEXT | iperf server |
| ping_interval_sec | INTEGER | Ping interval |
| iperf_interval_min | INTEGER | iperf interval |

## Screenshots

*Run the tool and open the dashboard to see the network health score, latency charts, bandwidth graphs, and availability donuts.*

## License

MIT
