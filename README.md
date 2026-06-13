# Pi-hole Upstream Watchdog Service

A watchdog service for Docker environments that automatically monitors and restores Pi-hole's DNS connectivity when upstream DNS resolution fails.

## The Problem It Solves

Transient network disruptions or upstream DNS failures can cause Pi-hole to lose contact with its upstream DNS servers, logging `WARNING: Connection error` messages.

When this routing dropout occurs:
1. **DNS Outages**: Network clients cannot resolve domain names.
2. **False Internet Failures**: Local devices report "No Internet Connection" because DNS queries fail, even though the physical gateway is active.

Manually resolving this requires logging in, restarting the Pi-hole stack, and restarting any other containers sharing the same interface to restore the routing table.

## How the Watchdog Helps

The watchdog automates recovery in three steps:

1. **Streams Logs**: It tails the Pi-hole container logs in real-time, monitoring for upstream connection error warnings.
2. **Double-Checks Outages**: If a warning is logged, it actively verifies connectivity from inside the Pi-hole container by pinging a public IP and running DNS queries.
3. **Self-Heals**: If all connectivity tests fail, it automatically restarts the Pi-hole compose stack and all other containers sharing the same network interface to restore routing.

---

## Configuration

All configuration is externalized in `fix-pihole.cfg`. If the file is missing, the script automatically generates it on its first run with sensible defaults:

- `TARGET_CONTAINER`: The name of the Pi-hole container to monitor (defaults to `pi-hole`).
- `DOCKER_ROOT`: The root directory where Docker Compose stacks are located.
- `COMPOSE_DIR`: The compose directory containing the Pi-hole stack.
- `SEARCH_STRING`: The log warning string to search for (defaults to `WARNING: Connection error`).
- `MACVLAN_STRING`: The name of the network interface shared with dependent stacks (leave empty to disable dependent stack restarts).
- `TEST_HOST`: External IP used to verify upstream connectivity.
- `TEST_DOMAIN`: External domain used to verify DNS resolution.
- `STABILIZE_COOLDOWN`: Time (in seconds) to wait for DNS to stabilize after a restart.
- `RECOVERY_COOLDOWN`: Cooldown (in seconds) to allow the network to settle after a fix before releasing the lock.
- `CHECK_INTERVAL`: Interval (in seconds) to poll if the container is running.
- `CONFIRM_WINDOW_SEC`: Time window (in seconds) in which consecutive errors trigger an outage check.
- `LOG_RETENTION_EVENT_HOURS` & `LOG_RETENTION_INFO_HOURS`: Retain event logs and info logs respectively (in hours).

---

## Usage

Manage the service using script flags:

- **Check status**: `bash fix-pihole.sh --check`
- **Install as a system service**: `sudo bash fix-pihole.sh --install`
- **Remove service**: `sudo bash fix-pihole.sh --purge`
- **Run in foreground (debug/testing)**: `bash fix-pihole.sh --watch`

---

## Installation

Create a directory for the script and download it using one of the following commands:

**Using curl:**
```bash
mkdir -p fix-pihole && cd fix-pihole && curl -sSL https://raw.githubusercontent.com/Arelius-D/fix-pihole/main/fix-pihole.sh -o fix-pihole.sh && chmod +x fix-pihole.sh
```

**Using wget:**
```bash
mkdir -p fix-pihole && cd fix-pihole && wget -q https://raw.githubusercontent.com/Arelius-D/fix-pihole/main/fix-pihole.sh -O fix-pihole.sh && chmod +x fix-pihole.sh
```
