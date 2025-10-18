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

On first startup (when `/.initialized` marker file doesn't exist), the container executes a comprehensive 8-step AD integration sequence:

#### 1. Environment Variable Validation
Checks for three required environment variables:
- `AD_ADMIN_USER`: Active Directory admin username
- `AD_ADMIN_PASS`: Password for the AD admin user
- `SAMBA_GLOBAL_CONFIG_realm`: The AD realm to join (e.g., EXAMPLE.COM)

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

**Exit Code:** 4 if realm join fails

#### 4. Domain Join (ADS Protocol)
Performs Samba-specific AD joining via `net ads join`, which:
- Creates a computer account in Active Directory
- Establishes the machine's identity in the domain
- Configures the ADS (Active Directory Services) client

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
Creates the `/.initialized` marker file to prevent re-initialization on subsequent container restarts, preserving existing AD membership.

### Subsequent Startups: Verification Mode

When the container starts and `/.initialized` exists:

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
1. **Environment Validation**: Verifies `AD_ADMIN_USER` and `AD_ADMIN_PASS` are defined
2. **Keytab Recreation**: Executes `net ads keytab create` to regenerate the keytab with current machine account keys
3. **Verification**: Lists keytab contents and logs success

**Exit Code:** 1 if refresh fails (credentials missing, network issues, or AD connectivity problems)

All output is logged to `/var/log/keytab-refresh.log` via cron redirection.

## Configuration Reference

### Environment Variables

#### Required (for initialization and refresh)
| Variable | Description | Format |
|----------|-------------|--------|
| `AD_ADMIN_USER` | Active Directory administrator username | `username` or `domain\username` |
| `AD_ADMIN_PASS` | Password for the AD administrator account | Plain text password |
| `SAMBA_GLOBAL_CONFIG_realm` | AD realm/domain name | Uppercase (e.g., `EXAMPLE.COM`) |

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
| 3 | Failed to discover realm (DNS/network issues, wrong realm name) |
| 4 | Failed to join realm (authentication issues, AD connectivity) |
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
| `cron` | Standard cron daemon for scheduling keytab refresh |

### File Locations

#### Scripts
- `/usr/local/bin/entrypoint.sh`: Container entrypoint (from `scripts/kerberos-entrypoint.sh`)
- `/usr/local/bin/kerberos-refresh.sh`: Keytab refresh script (from `scripts/kerberos-refresh.sh`)

#### State Files
- `/.initialized`: Marker file indicating completed initialization
- `/etc/krb5.keytab`: **THE critical authentication artifact** - Kerberos keytab file
- `/etc/krb5.conf`: Kerberos client configuration (created by realmd)
- `/var/log/keytab-refresh.log`: Refresh operation logs

#### Persistent Data Directories
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

For the container to persist AD membership across restarts, the following should be preserved (via volumes or persistent container):

- `/.initialized` - Initialization marker
- `/etc/krb5.keytab` - Authentication keys
- `/etc/krb5.conf` - Kerberos configuration
- `/var/lib/sss/db/` - SSSD cache
- `/var/lib/samba/private/` - Samba secrets
- Root crontab - Refresh schedule

**Important**: If the container is recreated (not just restarted), it will re-initialize and may create duplicate computer accounts in AD unless volumes are properly configured.

## Error Handling

Both scripts use strict error handling:
```bash
set -euo pipefail
```

- `-e`: Exit on any command failure
- `-u`: Exit on undefined variable usage
- `-o pipefail`: Exit if any command in a pipeline fails

This ensures failures are caught early and exit codes accurately reflect the failure point.

## Security Considerations

1. **Minimal Attack Surface**: Only AD client packages installed, no full Samba server
2. **Credential Protection**: Admin credentials passed via environment variables (should use Docker secrets in production)
3. **Keytab Security**: The `/etc/krb5.keytab` file contains sensitive authentication keys and should be protected
4. **Shared Authentication**: Keytab can be shared with other containers for unified AD authentication

## Troubleshooting

### Container fails to initialize
1. Check exit code to identify failure point (see Exit Codes section)
2. Verify environment variables are correctly set
3. Check DNS resolution for the AD realm
4. Verify network connectivity to domain controllers
5. Confirm admin credentials are valid

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
