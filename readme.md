# Kerberos Container for Active Directory Integration

This container provides shared Kerberos authentication for services that need to authenticate against Active Directory. It handles the complete lifecycle of AD domain joining, keytab creation, and ongoing maintenance of authentication credentials.

## Overview

### Purpose and Architecture

The Kerberos container is a minimal Ubuntu 24.04-based system that:
- Handles Active Directory domain joining
- Maintains Kerberos keytabs for shared authentication across services
- Does NOT run a full Samba server (only minimal AD client packages)
- Follows a "join once, maintain forever" pattern

**Key Design Principles:**
- **Minimal Package Set**: Only AD client tools installed, reducing attack surface and container size
- **Shared Keytab Pattern**: The keytab at `/etc/krb5.keytab` can be shared with other containers via volume mounts
- **Defensive Initialization**: Initialization marker prevents accidental re-joining (which could create duplicate AD computer accounts)
- **Proactive Refresh**: 7-day refresh cycle provides 4x safety margin before AD's 30-day password rotation

## Container Lifecycle

### First Startup: Complete Initialization

On first startup (when `/var/lib/kerberos/initialized` marker file doesn't exist), the container executes a comprehensive 9-step AD integration sequence:

#### 1. Environment Variable Validation
Checks for three required environment variables:
- `KERBEROS_ADMIN_USER`: Active Directory admin username
- `KERBEROS_ADMIN_PASSWORD`: Password for the AD admin user
- `KERBEROS_REALM`: The AD realm to join (e.g., EXAMPLE.COM)

Additionally, `KERBEROS_REALM` (and optionally `KERBEROS_WORKGROUP`) are used to dynamically generate `/etc/krb5.conf` and `/etc/samba/smb.conf` during initialization.

**Exit Code:** 2 if any required variables are missing

#### 2. Realm Discovery
Verifies that the specified AD realm is discoverable on the network using `realm discover`. This validates:
- DNS records for the domain
- Domain controller locations
- Network connectivity to AD services

**Exit Code:** 3 if realm discovery fails

#### 3. Realm Join
Joins the AD realm using `realm join`, which:
- Configures Kerberos client settings in `/etc/krb5.conf`
- Sets up SSSD (System Security Services Daemon) for user/group resolution
- Establishes trust relationship with the domain

**Pre-flight Checks (before realm join):**
- **DNS Verification**: Validates forward DNS lookup for the realm, displaying detailed diagnostics on failure (nslookup output, configured nameservers)
- **Credential Validation**: Tests authentication via `kinit` before modifying system configuration, ensuring admin credentials are valid

**Enhanced Error Diagnostics:**
- Captures verbose output from `realm join` command using `-v` flag
- On failure, displays combined stdout/stderr output
- Includes recent realmd service logs via `journalctl` for deeper troubleshooting
- No silent failures - all errors propagate with specific diagnostic information

**Exit Code:** 3 for DNS resolution failures, 4 for credential validation or realm join failures

#### 4. Domain Join (ADS Protocol)
Performs Samba-specific AD joining via `net ads join`, which:
- Creates a computer account in Active Directory
- Establishes the machine's identity in the domain
- Configures the ADS (Active Directory Services) client

**Pre-requisite Configuration:**
Before executing the domain join, the container dynamically generates `/etc/samba/smb.conf` with:
- `workgroup`: Derived from `KERBEROS_WORKGROUP` (or first component of `KERBEROS_REALM` if not set)
- `realm`: Set to `KERBEROS_REALM` value
- `security = ads`: Active Directory security mode
- `kerberos method = system keytab`: Use system-wide keytab for authentication

This configuration is required for `net ads join` to properly identify the AD domain and security settings.

**Exit Code:** 5 if domain join fails

#### 5. CIFS Service Principal Registration
Registers CIFS service principal names (SPNs) in Active Directory for SMB/CIFS authentication:
- Registers `cifs/hostname.domain.com` and `cifs/HOSTNAME` SPNs using `net ads setspn add`
- Required for Windows SMB clients to authenticate (they request `cifs/` tickets, not `host/` tickets)
- SPNs are verified with `net ads setspn list` after registration
- The keytab will include both `host/` and `cifs/` principals after creation

**Why CIFS SPNs Are Needed:**
Windows SMB clients always request Kerberos tickets for the `cifs/hostname` service when connecting to SMB shares. Without CIFS SPNs registered in AD and present in the keytab, SMB servers cannot decrypt these tickets, causing authentication failures even though the container is properly domain-joined.

**Exit Code:** 8 if CIFS SPN registration fails

#### 6. DNS Registration
Registers the container's presence in Active Directory DNS. Two modes are supported:

**Host DNS Registration Mode** (when both `HOST_IP` and `HOST_HOSTNAME` are set):
- Registers the Docker host's IP and hostname in AD DNS
- Used when the container provides authentication for services on the host
- Both variables must be set together or both omitted

**Container DNS Registration Mode** (default):
- Registers the container's own IP and hostname in AD DNS
- Used when the container is the primary service endpoint

**Exit Code:** 6 if DNS registration fails

#### 7. Keytab Creation
Creates the critical authentication artifact using `net ads keytab create`:
- Generates `/etc/krb5.keytab` containing encrypted keys for the machine account
- Enables services to authenticate to Kerberos without interactive login
- Keytab is machine-specific and tied to the AD computer account
- **Contains both `host/` and `cifs/` principals** for comprehensive service authentication

The keytab contents are verified using `klist -k /etc/krb5.keytab`, and the presence of CIFS principals is specifically validated.

**Exit Code:** 7 if keytab creation fails, 8 if CIFS principals are missing from keytab

#### 8. Cron Job Setup
Configures automated keytab maintenance:
- **Schedule**: `0 0 */7 * *` (midnight every 7 days)
- **Command**: `/usr/local/bin/kerberos-refresh.sh`
- **Logging**: Output redirected to `/var/log/keytab-refresh.log`
- **Rationale**: 7-day cycle stays well ahead of AD's default 30-day password rotation

#### 9. Initialization Marker
Creates the `/var/lib/kerberos/initialized` marker file to prevent re-initialization on subsequent container restarts, preserving existing AD membership.

### Subsequent Startups: Verification Mode

When the container starts and `/var/lib/kerberos/initialized` exists:

1. Skips all initialization steps
2. Runs a non-blocking membership verification check (`net ads testjoin`)
3. Warns if verification fails but continues (allows manual intervention)
4. Confirms membership if verification succeeds

This design allows the container to start even during temporary AD connectivity issues.

## Keytab Refresh Mechanism

Active Directory rotates machine account passwords every 30 days by default. The `kerberos-refresh.sh` script maintains keytab validity through periodic refresh:

### Refresh Process

**Schedule**: Every 7 days (4x safety margin before 30-day rotation)

**Steps:**
1. **Environment Validation**: Verifies `KERBEROS_ADMIN_USER` and `KERBEROS_ADMIN_PASSWORD` are defined
2. **CIFS SPN Verification**: Checks if CIFS SPNs are still registered in AD, re-registers if missing
3. **Keytab Recreation**: Executes `net ads keytab create` to regenerate the keytab with current machine account keys (including any re-registered CIFS SPNs)
4. **Verification**: Lists keytab contents, verifies CIFS principals are present, and logs success

**Exit Code:** 1 if refresh fails (credentials missing, network issues, or AD connectivity problems)

**Note**: CIFS SPNs should remain registered in AD between refreshes. The verification step ensures they persist and automatically re-registers them if they were removed (e.g., manual AD changes or account recreation).

All output is logged to `/var/log/keytab-refresh.log` via cron redirection.

## Winbind Proxy for Multi-Container SMB Deployments

This container provides winbind proxy functionality for multi-container architectures where SMB services run in separate containers with isolated Docker networks.

### Architecture Overview

In deployments with isolated networks (`internal: true` in docker-compose), SMB containers cannot reach Active Directory domain controllers directly. The kerberos container acts as a proxy by exposing its winbind daemon over the internal network, enabling SMB containers to query AD for user/group information.

```
┌──────────────────────────┐
│  Kerberos Container      │
│  - Joined to AD          │
│  - Exports keytab        │
│  - Runs winbind          │
│  - Winbind RPC proxy     │
└───────────┬──────────────┘
            │ Internal Network (isolated)
    ┌───────┴────────┐
    ↓                ↓
┌──────────┐    ┌──────────┐
│ SMB1     │    │ SMB2     │
│ - smbd   │    │ - smbd   │
│ - Queries│    │ - Queries│
│   winbind│    │   winbind│
│   proxy  │    │   proxy  │
└──────────┘    └──────────┘
```

### How It Works

1. **CIFS Authentication**: Windows clients request `cifs/hostname` tickets from AD
2. **Ticket Decryption**: SMB containers decrypt tickets using the shared keytab (contains CIFS principals)
3. **Authorization Check**: SMB needs to verify user permissions (e.g., group membership)
4. **Winbind Proxy Query**: SMB container queries the kerberos container's winbind via RPC
5. **AD Lookup**: Kerberos winbind forwards the query to AD (has external network access)
6. **SID/UID Mapping**: Winbind returns user SID, group memberships, and Unix UID/GID mappings
7. **Access Decision**: SMB grants or denies file access based on group membership

### Automatic Network Security

The container automatically detects internal (isolated) Docker networks and restricts winbind access to only those networks plus localhost.

**Detection Method**: Tests external connectivity by pinging 8.8.8.8 from each network interface
- Networks that **cannot** reach external hosts = internal (isolated) networks
- Networks that **can** reach external hosts = external networks (excluded from winbind access)

**Network Address Calculation**: Properly calculates network addresses from IP/CIDR using bitwise operations, supporting any subnet mask (/8, /16, /20, /24, etc.)

**Generated Configuration**:
```ini
[global]
   # ... other settings ...
   rpc_server:winbind = embedded
   rpc_daemon:winbindd = fork
   hosts allow = 127.0.0.1 172.18.0.0/16
```

### Configuration

The winbind proxy is **automatically configured during initialization**:
- Enabled by default when the container joins AD
- No additional environment variables required
- Security automatically configured based on network topology

**Automatic Settings in smb.conf**:
- `rpc_server:winbind = embedded` - Enable RPC server within winbind process
- `rpc_daemon:winbindd = fork` - Use forking model for concurrent RPC requests
- `hosts allow` - Dynamically generated list of internal networks + localhost

### Using the Winbind Proxy in SMB Containers

SMB containers sharing the keytab from this container automatically have access to the winbind proxy for AD user/group lookups.

**Requirements**:
1. **Shared Keytab**: Mount the same keytab volume from this container
2. **Network Access**: Connect to the same internal network as the kerberos container
3. **Hostname Resolution**: Able to resolve the kerberos container's hostname

**Example docker-compose.yml**:
```yaml
services:
  kerberos:
    image: your-kerberos-image:latest
    environment:
      KERBEROS_ADMIN_USER: "admin"
      KERBEROS_ADMIN_PASSWORD: "password"
      KERBEROS_REALM: "EXAMPLE.COM"
      KRB5_CONFIG: "/etc/krb5/krb5.conf"
      KRB5_KTNAME: "FILE:/etc/krb5/krb5.keytab"
    volumes:
      - kerberos-state:/var/lib/kerberos
      - kerberos-config:/etc/krb5
    networks:
      - internal-network
      - external-network

  smb1:
    image: your-samba-image:latest
    volumes:
      - kerberos-config:/etc/krb5:ro
    networks:
      - smb1-isolated  # SMB container's own network
      - internal-network  # Access to kerberos winbind
    depends_on:
      - kerberos

networks:
  internal-network:
    internal: true  # Isolated - no external access
  external-network:
    internal: false  # Kerberos can reach AD
  smb1-isolated:
    internal: true

volumes:
  kerberos-state:
  kerberos-config:
```

### Verification Commands

**From kerberos container (verify winbind works)**:
```bash
# Test winbind functionality
wbinfo -u  # List AD users
wbinfo -g  # List AD groups
wbinfo -t  # Test trust

# Verify winbind is running
ps aux | grep winbindd
```

**From SMB container (verify can query winbind)**:
```bash
# Test AD user resolution
getent passwd ad_username

# Test AD group resolution
getent group ad_groupname

# View Samba logs for winbind activity
tail -f /var/log/samba/log.smbd | grep -i winbind
```

### Security Considerations

**Network Isolation**: The winbind RPC server is only accessible from internal Docker networks and localhost. External networks are automatically excluded from `hosts allow`, preventing unauthorized access.

**Why This is Secure**:
- Ping-based detection ensures only isolated networks are allowed
- External-facing networks cannot access winbind RPC
- Even if an attacker gains access to an external network, they cannot query AD through winbind
- SMB containers on isolated networks can safely use winbind without AD credentials

**What is Exposed**:
- AD user/group lookups (read-only queries)
- SID to UID/GID mapping
- Group membership information

**What is NOT Exposed**:
- AD admin credentials (only kerberos container has these)
- Ability to modify AD (winbind is read-only)
- Kerberos ticket creation (tickets come from AD via keytab)

## Configuration Reference

### Environment Variables

#### Required (for initialization and refresh)
| Variable | Description | Format |
|----------|-------------|--------|
| `KERBEROS_ADMIN_USER` | Active Directory administrator username | `username` or `domain\username` |
| `KERBEROS_ADMIN_PASSWORD` | Password for the AD administrator account | Plain text password |
| `KERBEROS_REALM` | AD realm/domain name | Uppercase (e.g., `EXAMPLE.COM`) |

#### Kerberos Configuration (krb5.conf)

The container dynamically generates `/etc/krb5.conf` from environment variables during startup. This eliminates the need for bind-mounting configuration files and enables proper persistence via Docker volumes.

##### Required
| Variable | Description | Example |
|----------|-------------|---------|
| `KERBEROS_REALM` | Active Directory realm (uppercase) | `EXAMPLE.COM` |

##### Optional (with defaults)
| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `KERBEROS_DOMAIN` | DNS domain name (lowercase) | Lowercase version of KERBEROS_REALM | `example.com` |
| `KERBEROS_KDC_SERVERS` | Space-separated KDC server list | Auto-discovered via DNS | `dc1.example.com dc2.example.com` |
| `KERBEROS_TICKET_LIFETIME` | Kerberos ticket lifetime | `24h` | `12h` |
| `KERBEROS_RENEW_LIFETIME` | Ticket renewal lifetime | `7d` | `30d` |
| `KERBEROS_DNS_LOOKUP_KDC` | Use DNS to locate KDCs | `true` | `false` |
| `KERBEROS_DNS_LOOKUP_REALM` | Use DNS to locate realm | `false` | `true` |
| `KERBEROS_FORWARDABLE` | Allow ticket forwarding | `true` | `false` |
| `KERBEROS_RDNS` | Enable reverse DNS lookups | `false` | `true` |
| `KERBEROS_WORKGROUP` | NetBIOS workgroup/domain name for AD | First component of KERBEROS_REALM | `TEMPCO` |
| `KRB5_CONFIG` | Custom path for krb5.conf file | `/etc/krb5.conf` | `/etc/krb5/krb5.conf` |

**Important Notes:**
- The configuration file is regenerated on every container start, ensuring consistency with environment variables
- If KDC servers are not specified, they will be auto-discovered via DNS SRV records
- Manual modifications to the krb5.conf file will be lost on restart - use environment variables instead
- To share krb5.conf between containers (e.g., with Samba containers), set `KRB5_CONFIG=/etc/krb5/krb5.conf` and mount `/etc/krb5/` as a named volume
- Docker named volumes can only mount to directories, not individual files - use `KRB5_CONFIG` to move krb5.conf into a directory for sharing
- `KERBEROS_WORKGROUP`: The default (first component of realm) may not match your actual AD workgroup for multi-component realms (e.g., `WOODDALE.TEMPCO.COM` → defaults to `WOODDALE` but actual workgroup might be `TEMPCO`). Set explicitly if the derived value is incorrect.

#### Optional (for keytab configuration)
| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `KRB5_KTNAME` | Custom path for Kerberos keytab (must include FILE: prefix) | `FILE:/etc/krb5.keytab` | `FILE:/etc/krb5/krb5.keytab` |

**Important Notes:**
- The `KRB5_KTNAME` variable must include the `FILE:` prefix for proper Kerberos functionality
- To share the keytab between containers, set `KRB5_KTNAME=FILE:/etc/krb5/krb5.keytab` and mount `/etc/krb5/` as a named volume
- Combined with `KRB5_CONFIG`, both krb5.conf and krb5.keytab can share the same `/etc/krb5/` volume mount

#### Optional (for host DNS registration)
| Variable | Description | Format |
|----------|-------------|--------|
| `HOST_IP` | IP address of the Docker host | `192.168.1.100` |
| `HOST_HOSTNAME` | Hostname of the Docker host | `myserver.example.com` |

**Note**: Both `HOST_IP` and `HOST_HOSTNAME` must be set together or both omitted.

### Exit Codes

#### kerberos-entrypoint.sh
| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Unknown error |
| 2 | Required environment variables not defined |
| 3 | Failed to discover realm or DNS verification failed (DNS/network issues, wrong realm name) |
| 4 | Failed credential validation or realm join (invalid credentials, authentication issues, AD connectivity) |
| 5 | Failed to join domain (ADS protocol issues) |
| 6 | Failed to register DNS entry (AD DNS service issues) |
| 7 | Failed to create keytab (permission issues, AD configuration) |
| 8 | Failed to register CIFS service principal names or CIFS principals missing from keytab |

#### kerberos-refresh.sh
| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Failed to refresh keytab or missing credentials |

### Package Dependencies

The container installs only minimal AD integration packages:

| Package | Role |
|---------|------|
| `realmd` | High-level tool for discovering and joining AD/Kerberos realms |
| `sssd-ad` | System Security Services Daemon with Active Directory provider |
| `sssd-tools` | Command-line utilities for managing SSSD |
| `adcli` | Low-level Active Directory client operations library |
| `krb5-user` | Kerberos client utilities (kinit, klist, kdestroy) |
| `winbind` | Samba's NT domain client service for Unix/AD integration and winbind proxy |
| `samba-common-bin` | Common Samba utilities including the `net` command |
| `dnsutils` | DNS query tools (nslookup, dig) for pre-flight DNS verification |
| `iputils-ping` | Ping utility for network isolation detection (winbind security) |
| `cron` | Standard cron daemon for scheduling keytab refresh |

### File Locations

#### Scripts
- `/usr/local/bin/entrypoint.sh`: Container entrypoint (from `scripts/kerberos-entrypoint.sh`)
- `/usr/local/bin/kerberos-refresh.sh`: Keytab refresh script (from `scripts/kerberos-refresh.sh`)

#### State Files
- `/var/lib/kerberos/initialized`: Marker file indicating completed initialization
- `/etc/krb5.keytab`: **THE critical authentication artifact** - Kerberos keytab file (customizable via `KRB5_KTNAME`)
- `/etc/krb5.conf`: Kerberos client configuration (customizable via `KRB5_CONFIG`)
- `/var/log/keytab-refresh.log`: Refresh operation logs

#### Persistent Data Directories
- `/var/lib/kerberos/`: Container state directory (contains initialization marker)
- `/var/lib/samba/private/`: Samba machine secrets and trust relationships
- `/var/lib/sss/db/`: SSSD cache databases

## Command Reference

### Realm Operations
```bash
# Discover AD realm
realm --install / -v discover EXAMPLE.COM

# Join AD realm
realm --install / join EXAMPLE.COM -U admin_user

# List joined realms and their status
realm --install / -v list EXAMPLE.COM
```

### Domain Operations
```bash
# Join AD domain (after realm join)
net ads join -U"admin_user%password"

# Test domain membership
net ads testjoin

# Get domain information
net ads info

# Register DNS (host mode)
net ads dns register hostname.example.com 192.168.1.100 -U"admin_user%password"

# Register DNS (container mode)
net ads dns register -U"admin_user%password"
```

### Service Principal Name (SPN) Operations
```bash
# Register CIFS SPNs for SMB/CIFS authentication
net ads setspn add "cifs/$(hostname -f)" -U"admin_user%password"
net ads setspn add "cifs/$(hostname -s)" -U"admin_user%password"

# List all SPNs registered for this computer
net ads setspn list "$(hostname -s)" -U"admin_user%password"

# Expected output includes:
#   host/hostname.domain.com
#   host/HOSTNAME
#   cifs/hostname.domain.com
#   cifs/HOSTNAME
```

### Keytab Operations
```bash
# Create/refresh keytab
net ads keytab create -U"admin_user%password"

# List keytab contents
klist -k /etc/krb5.keytab

# Verify CIFS principals are present
klist -k /etc/krb5.keytab | grep cifs

# Expected output:
#   2 cifs/hostname.domain.com@REALM.COM
#   2 cifs/HOSTNAME@REALM.COM
```

### Cron Management
```bash
# View current crontab
crontab -l

# The installed refresh job runs at midnight every 7 days
0 0 */7 * * /usr/local/bin/kerberos-refresh.sh >> /var/log/keytab-refresh.log 2>&1
```

## Container Startup Sequence

The Dockerfile defines the following startup process:

1. **ENTRYPOINT**: `/usr/local/bin/entrypoint.sh` runs first
   - Handles all initialization or verification logic
   - Uses `exec "$@"` to replace itself with the CMD

2. **CMD**: After entrypoint completes, services start:
   - `service winbind start`: Starts winbind daemon for AD integration
   - `cron`: Starts cron daemon for scheduled keytab refresh
   - `tail -f /dev/null`: Keeps container running indefinitely

## Health Monitoring

The container includes a Docker HEALTHCHECK that periodically verifies the container is functioning correctly. A "healthy" container has both a valid keytab and working Active Directory connectivity.

### Docker HEALTHCHECK

**What the health check verifies:**

1. **Keytab file exists and is readable** - Uses `klist -k` to verify the keytab at the configured location (default `/etc/krb5.keytab`) contains valid Kerberos credentials. Without this file, no service can authenticate to Active Directory.

2. **Active Directory connectivity is working** - Uses `net ads testjoin` to test communication with AD domain controllers, verify the machine account is still valid in Active Directory, and ensure DNS resolution is working.

**Health check command:**
```bash
keytab="${KRB5_KTNAME:-FILE:/etc/krb5.keytab}" && \
klist -k "${keytab#FILE:}" && \
net ads testjoin || exit 1
```

**Container health states:**
- **starting** - During the start period (first 120 seconds), health check failures are ignored to allow initialization to complete
- **healthy** - Both keytab verification and AD connectivity tests pass
- **unhealthy** - Health check has failed 3 consecutive times (indicating 15 minutes of sustained issues)

### Health Check Configuration

The HEALTHCHECK is configured with timing parameters that balance timely issue detection with operational overhead:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| **interval** | 5m | Health checks run every 5 minutes after startup completes. This balances timely detection of AD connectivity issues with minimal overhead on the container and AD infrastructure. |
| **timeout** | 10s | Maximum time allowed for the health check to complete. Generous enough for `klist -k` (local file read, milliseconds) and `net ads testjoin` (network operation, typically 1-3 seconds) while allowing for temporary network latency. |
| **start-period** | 120s | Grace period during which health check failures are ignored. Accommodates the 8-step initialization sequence on first startup (realm discovery, DNS verification, credential validation, realm join, domain join, DNS registration, keytab creation). |
| **retries** | 3 | Number of consecutive failures before marking container as unhealthy. Handles transient network glitches, temporary AD service issues, and brief DNS resolution delays. Container only marked unhealthy after sustained failures (3 × 5 minute intervals = 15 minutes). |

### Viewing Health Status

**Check container health status:**
```bash
docker ps
```

The `STATUS` column shows health state:
```
CONTAINER ID   IMAGE              STATUS
abc123def456   kerberos:latest    Up 10 minutes (healthy)
```

**View detailed health check history:**
```bash
docker inspect <container-name-or-id> | jq '.[0].State.Health'
```

Example output:
```json
{
  "Status": "healthy",
  "FailingStreak": 0,
  "Log": [
    {
      "Start": "2025-10-20T10:15:00.000000000Z",
      "End": "2025-10-20T10:15:01.234567890Z",
      "ExitCode": 0,
      "Output": "Keytab contains 2 principals\nJoin to domain is OK\n"
    }
  ]
}
```

### Troubleshooting Unhealthy Containers

If a container shows `unhealthy` status, follow these diagnostic steps:

**1. Check container logs:**
```bash
docker logs <container-name>
```
Look for errors in the initialization sequence or service startup.

**2. Manually verify keytab:**
```bash
docker exec <container-name> klist -k /etc/krb5.keytab
```
Should list principals like `host/hostname@REALM.COM`. If the file doesn't exist or is empty, the container needs re-initialization.

**3. Manually test domain connectivity:**
```bash
docker exec <container-name> net ads testjoin
```
Should output "Join to domain is OK". Failures indicate:
- **Network connectivity issues** - Cannot reach domain controllers
- **DNS resolution problems** - Cannot resolve domain controller hostnames
- **Expired machine account** - Computer account removed from AD or password expired
- **AD service outage** - Domain controllers unavailable

**4. Verify AD connectivity from the host:**
```bash
nslookup <domain-controller-hostname>
ping <domain-controller-hostname>
```
Ensures the network path to AD is available.

**5. Check firewall rules:**
Ensure the container can reach domain controllers on required ports:
- TCP/UDP 88 (Kerberos)
- TCP/UDP 389 (LDAP)
- TCP 445 (SMB)
- TCP/UDP 53 (DNS)

**6. Re-initialize if needed:**
If the keytab is missing or the machine account is invalid, remove the initialization marker to force a fresh domain join:
```bash
docker exec <container-name> rm /var/lib/kerberos/initialized
docker restart <container-name>
```

**Warning:** Re-initialization will leave a stale computer account in AD if the original account wasn't properly removed. Clean up stale accounts manually in Active Directory Users and Computers.

## Persistence Considerations

For the container to persist AD membership across restarts, the following should be preserved via named volumes:

- `/var/lib/kerberos/` - Container state directory (contains initialization marker)
- `/etc/krb5/` - Kerberos configuration and keytab (when using directory-based sharing)
- `/var/lib/samba/private/` - Samba machine secrets and trust relationships
- `/var/lib/sss/db/` - SSSD cache databases

**Note:** The root crontab is recreated during initialization and doesn't need persistence.

### Why Persistence Matters

**Without persistent volumes, recreating the container causes problems:**

1. **Duplicate Computer Accounts**: Each realm/domain join creates a computer account in Active Directory. Without running `realm leave` / `net ads leave` before destroying the container, AD accumulates stale computer accounts.

2. **Computer Account Quota**: AD has a default limit of 10 computer accounts per user. Repeatedly joining without cleanup will hit this limit and prevent new joins.

3. **Security Audit Trail**: Creates confusing audit logs with multiple join/leave events that make it difficult to track actual security events.

4. **Unnecessary Load**: Hits the domain controllers unnecessarily on every container restart, wasting resources.

5. **The Initialization Marker Exists for This Reason**: The entrypoint script explicitly checks for this marker to avoid re-joining on container restart.

### Docker Compose Volume Configuration

**Recommended approach using directory-based volumes:**

**Directory-based configuration (recommended for sharing with other containers):**
```yaml
services:
  kerberos:
    image: your-kerberos-image:latest
    environment:
      KERBEROS_ADMIN_USER: "admin"
      KERBEROS_ADMIN_PASSWORD: "password"
      KERBEROS_REALM: "EXAMPLE.COM"
      # KERBEROS_DOMAIN defaults to "example.com" (lowercase realm)
      # KERBEROS_KDC_SERVERS will be auto-discovered via DNS

      # Use directory-based paths for volume sharing
      KRB5_CONFIG: "/etc/krb5/krb5.conf"
      KRB5_KTNAME: "FILE:/etc/krb5/krb5.keytab"
    volumes:
      # Persist AD membership state using directories
      - kerberos-state:/var/lib/kerberos
      - kerberos-config:/etc/krb5
      - kerberos-samba-data:/var/lib/samba/private
      - kerberos-sssd:/var/lib/sss/db

volumes:
  kerberos-state:
  kerberos-config:
  kerberos-samba-data:
  kerberos-sssd:
```

**Sharing Kerberos credentials with Samba containers:**
```yaml
services:
  kerberos:
    image: your-kerberos-image:latest
    environment:
      KERBEROS_ADMIN_USER: "admin"
      KERBEROS_ADMIN_PASSWORD: "password"
      KERBEROS_REALM: "EXAMPLE.COM"
      KRB5_CONFIG: "/etc/krb5/krb5.conf"
      KRB5_KTNAME: "FILE:/etc/krb5/krb5.keytab"
    volumes:
      - kerberos-state:/var/lib/kerberos
      - kerberos-config:/etc/krb5
      - kerberos-samba-data:/var/lib/samba/private
      - kerberos-sssd:/var/lib/sss/db

  samba1:
    image: your-samba-image:latest
    environment:
      # Use the same Kerberos config and keytab
      KRB5_CONFIG: "/etc/krb5/krb5.conf"
      KRB5_KTNAME: "FILE:/etc/krb5/krb5.keytab"
    volumes:
      # Mount the same Kerberos config volume (read-only recommended)
      - kerberos-config:/etc/krb5:ro
    depends_on:
      - kerberos

  samba2:
    image: your-samba-image:latest
    environment:
      KRB5_CONFIG: "/etc/krb5/krb5.conf"
      KRB5_KTNAME: "FILE:/etc/krb5/krb5.keytab"
    volumes:
      - kerberos-config:/etc/krb5:ro
    depends_on:
      - kerberos

volumes:
  kerberos-state:
  kerberos-config:
  kerberos-samba-data:
  kerberos-sssd:
```

**Legacy configuration (backward compatible, no sharing):**
```yaml
services:
  kerberos:
    image: your-kerberos-image:latest
    environment:
      KERBEROS_ADMIN_USER: "admin"
      KERBEROS_ADMIN_PASSWORD: "password"
      KERBEROS_REALM: "EXAMPLE.COM"
      # Using default paths (no KRB5_CONFIG or KRB5_KTNAME needed)
    volumes:
      # Single-container setup (no sharing)
      - kerberos-state:/var/lib/kerberos
      - kerberos-samba-data:/var/lib/samba/private
      - kerberos-sssd:/var/lib/sss/db

volumes:
  kerberos-state:
  kerberos-samba-data:
  kerberos-sssd:
```

**Important Notes:**
- Docker named volumes can only mount to directories, not individual files
- Use `KRB5_CONFIG` and `KRB5_KTNAME` to move Kerberos files into `/etc/krb5/` for sharing
- The `KRB5_KTNAME` variable must include the `FILE:` prefix
- Both krb5.conf and krb5.keytab can share the same `/etc/krb5/` volume mount
- Mount the shared volume as read-only (`:ro`) in consuming containers to prevent accidental modifications
- All state files must persist for the container to maintain AD membership across recreations

**Note**: The root crontab is stored in `/var/spool/cron/crontabs/root` and typically doesn't need explicit persistence as it's recreated during initialization.

## Error Handling

Both scripts use strict error handling:
```bash
set -euo pipefail
```

- `-e`: Exit on any command failure
- `-u`: Exit on undefined variable usage
- `-o pipefail`: Exit if any command in a pipeline fails

This ensures failures are caught early and exit codes accurately reflect the failure point.

### Enhanced Error Diagnostics

The entrypoint script implements comprehensive error diagnostics:

**Pre-flight Validation:**
- DNS forward lookup verification before realm join attempts
- Credential validation via `kinit` before modifying system configuration
- Both checks provide detailed error output to help identify root causes

**Verbose Error Capture:**
- Realm join operations use verbose mode (`-v` flag) for detailed output
- Combined stdout/stderr capture preserves all diagnostic information
- Recent realmd service logs included via `journalctl` when available

**No Silent Failures:**
- Removed all error suppression patterns (`|| true`)
- All errors properly propagate with specific exit codes
- Error messages include contextual information (DNS servers, Kerberos errors, realm output)

## Security Considerations

1. **Minimal Attack Surface**: Only AD client packages installed, no full Samba server
2. **Credential Protection**: Admin credentials passed via environment variables (should use Docker secrets in production)
3. **Keytab Security**: The `/etc/krb5.keytab` file contains sensitive authentication keys and should be protected
4. **Shared Authentication**: Keytab can be shared with other containers for unified AD authentication

### Using Docker Secrets for Credentials

**Instead of plain environment variables, use Docker secrets in production:**

```yaml
services:
  kerberos:
    image: your-kerberos-image:latest
    environment:
      KERBEROS_ADMIN_USER: "admin"
      KERBEROS_REALM: "EXAMPLE.COM"
    secrets:
      - kerberos_admin_password
    # Map secret to environment variable expected by the container
    entrypoint:
      - /bin/bash
      - -c
      - |
        export KERBEROS_ADMIN_PASSWORD=$(cat /run/secrets/kerberos_admin_password)
        exec /usr/local/bin/entrypoint.sh

secrets:
  kerberos_admin_password:
    file: ./secrets/kerberos_admin_password.txt
```

**Or using Docker Swarm secrets:**

```yaml
services:
  kerberos:
    image: your-kerberos-image:latest
    environment:
      KERBEROS_ADMIN_USER: "admin"
      KERBEROS_REALM: "EXAMPLE.COM"
    secrets:
      - kerberos_admin_password
    entrypoint:
      - /bin/bash
      - -c
      - |
        export KERBEROS_ADMIN_PASSWORD=$(cat /run/secrets/kerberos_admin_password)
        exec /usr/local/bin/entrypoint.sh

secrets:
  kerberos_admin_password:
    external: true
```

**Create the secret:**
```bash
# For file-based secrets
echo "your-password" > ./secrets/ad_admin_password.txt
chmod 600 ./secrets/ad_admin_password.txt

# For Docker Swarm
echo "your-password" | docker secret create ad_admin_password -
```

## Troubleshooting

### Container fails to initialize
1. **Check exit code** to identify failure point (see Exit Codes section)
2. **Review container logs** - the entrypoint script now provides detailed diagnostic output:
   - DNS verification results with nslookup output and configured nameservers
   - Credential validation errors with specific Kerberos error messages
   - Verbose realm join output from `realm join -v`
   - Recent realmd service logs via `journalctl` (when available)
3. Verify environment variables are correctly set
4. Check DNS resolution for the AD realm
5. Verify network connectivity to domain controllers
6. Confirm admin credentials are valid

**Improved Error Diagnostics (as of latest version):**

The container now performs pre-flight checks and provides comprehensive error output:
- **DNS failures**: Shows nslookup results and `/etc/resolv.conf` nameserver configuration
- **Credential failures**: Displays specific `kinit` error messages before attempting realm join
- **Realm join failures**: Captures verbose output and includes recent realmd logs
- **No silent failures**: All errors propagate with detailed diagnostic information

**DNS Verification Commands (for manual troubleshooting):**
```bash
# Check if the AD realm resolves
nslookup EXAMPLE.COM

# Check LDAP service discovery (critical for AD)
nslookup -type=SRV _ldap._tcp.dc._msdcs.EXAMPLE.COM

# Check Kerberos service discovery
nslookup -type=SRV _kerberos._tcp.EXAMPLE.COM

# Alternative using dig
dig EXAMPLE.COM A
dig _ldap._tcp.dc._msdcs.EXAMPLE.COM SRV
dig _kerberos._tcp.EXAMPLE.COM SRV
```

**Network Connectivity Verification:**
```bash
# Test LDAP connectivity to domain controller
nc -zv dc.example.com 389

# Test Kerberos connectivity
nc -zv dc.example.com 88

# Test Kerberos password change service
nc -zv dc.example.com 464

# Test DNS connectivity
nc -zv dc.example.com 53
```

### Keytab refresh fails
1. Check `/var/log/keytab-refresh.log` for error details
2. Verify admin credentials are still valid
3. Check AD connectivity from the container
4. Verify machine account still exists in AD

### Services can't authenticate with keytab
1. Verify keytab file exists: `ls -l /etc/krb5.keytab`
2. Check keytab contents: `klist -k /etc/krb5.keytab`
3. Test AD membership: `net ads testjoin`
4. Check service configuration for correct principal names

### SMB/CIFS authentication failures from Windows clients

**Symptom**: Windows clients cannot connect to SMB shares even though the container is domain-joined

**Cause**: Missing CIFS service principals in the keytab

**Diagnosis**:
```bash
# Check if CIFS principals exist in keytab
docker exec <container-name> klist -k /etc/krb5.keytab | grep cifs

# Check if CIFS SPNs are registered in AD
docker exec <container-name> net ads setspn list "$(hostname -s)"
```

**Expected output**:
- Keytab should contain: `cifs/hostname.domain.com@REALM` and `cifs/HOSTNAME@REALM`
- SPN list should include both `cifs/` entries

**Solution**:
If CIFS principals are missing, the container may have been initialized before CIFS SPN support was added. Reinitialize the container:
```bash
# Remove initialization marker to force re-initialization
docker exec <container-name> rm /var/lib/kerberos/initialized

# Restart container to trigger full initialization with CIFS SPN registration
docker restart <container-name>
```

**Why this happens**:
Windows SMB clients always request Kerberos tickets for the `cifs/hostname` service (not `host/hostname`). Without CIFS principals in the keytab, the SMB server cannot decrypt these tickets, causing authentication failures.

### krb5.conf keeps regenerating and losing custom changes

**This is expected behavior.** The container regenerates `/etc/krb5.conf` from environment variables on every start to ensure consistency.

**To customize the configuration:**
1. Set the appropriate `KERBEROS_*` environment variables (see Configuration Reference)
2. Restart the container for changes to take effect

**Why this approach:**
- Configuration always matches your environment variables
- No drift between intended and actual configuration
- Eliminates bind mount inode locking issues that prevent atomic file operations
- Simpler deployment without maintaining separate config files
