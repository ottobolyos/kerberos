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

On first startup (when `/var/lib/kerberos/initialized` marker file doesn't exist), the container executes a comprehensive 8-step AD integration sequence:

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

#### 5. DNS Registration
Registers the container's presence in Active Directory DNS. Two modes are supported:

**Host DNS Registration Mode** (when both `HOST_IP` and `HOST_HOSTNAME` are set):
- Registers the Docker host's IP and hostname in AD DNS
- Used when the container provides authentication for services on the host
- Both variables must be set together or both omitted

**Container DNS Registration Mode** (default):
- Registers the container's own IP and hostname in AD DNS
- Used when the container is the primary service endpoint

**Exit Code:** 6 if DNS registration fails

#### 6. Keytab Creation
Creates the critical authentication artifact using `net ads keytab create`:
- Generates `/etc/krb5.keytab` containing encrypted keys for the machine account
- Enables services to authenticate to Kerberos without interactive login
- Keytab is machine-specific and tied to the AD computer account

The keytab contents are verified using `klist -k /etc/krb5.keytab`.

**Exit Code:** 7 if keytab creation fails

#### 7. Cron Job Setup
Configures automated keytab maintenance:
- **Schedule**: `0 0 */7 * *` (midnight every 7 days)
- **Command**: `/usr/local/bin/kerberos-refresh.sh`
- **Logging**: Output redirected to `/var/log/keytab-refresh.log`
- **Rationale**: 7-day cycle stays well ahead of AD's default 30-day password rotation

#### 8. Initialization Marker
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
2. **Keytab Recreation**: Executes `net ads keytab create` to regenerate the keytab with current machine account keys
3. **Verification**: Lists keytab contents and logs success

**Exit Code:** 1 if refresh fails (credentials missing, network issues, or AD connectivity problems)

All output is logged to `/var/log/keytab-refresh.log` via cron redirection.

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
| `winbind` | Samba's NT domain client service for Unix/AD integration |
| `samba-common-bin` | Common Samba utilities including the `net` command |
| `dnsutils` | DNS query tools (nslookup, dig) for pre-flight DNS verification |
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

### Keytab Operations
```bash
# Create/refresh keytab
net ads keytab create -U"admin_user%password"

# List keytab contents
klist -k /etc/krb5.keytab
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
