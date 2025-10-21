# Kerberos Container Project

This repository contains a containerized Active Directory integration service that handles Kerberos authentication for other services.

## Project Overview

This is a minimal Ubuntu 24.04-based container that:
- Joins an Active Directory domain
- Dynamically generates Kerberos configuration (krb5.conf) and Samba configuration (smb.conf) from environment variables
- Creates and maintains Kerberos keytabs for shared authentication (including CIFS service principals)
- Uses standard Kerberos environment variables (KRB5_CONFIG, KRB5_KTNAME) for configuration
- Provides keytabs to other services via directory-based volume mounts
- Automatically refreshes keytabs to stay ahead of AD password rotation
- Monitors container health via Docker HEALTHCHECK (keytab validity and AD connectivity)
- Exposes winbind proxy via TCP socket forwarding (socat) for multi-container SMB deployments with network isolation

**Key Files:**
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/readme.md` - Complete container documentation including architecture, configuration, and troubleshooting
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/kerberos.dockerfile` - Container image definition
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/scripts/kerberos-entrypoint.sh` - Container initialization and AD join logic
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/scripts/kerberos-refresh.sh` - Keytab refresh mechanism (runs every 7 days)
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/scripts/winbind-proxy-start.sh` - TCP proxy startup for remote winbind access
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/scripts/publish_docker_image.sh` - Docker image publishing script

## Key Architectural Patterns

### Dynamic Configuration Generation

The container dynamically generates configuration files from environment variables during initialization:

#### Standard Kerberos Environment Variables

**KRB5_CONFIG**: Path to the krb5.conf file (default: `/etc/krb5.conf`)
- Allows customizing where krb5.conf is located
- Used for directory-based volume sharing (e.g., `/etc/krb5/krb5.conf`)
- Referenced in scripts as: `KRB5_CONFIG_FILE="${KRB5_CONFIG:-/etc/krb5.conf}"`

**KRB5_KTNAME**: Keytab location with type prefix (default: `FILE:/etc/krb5.keytab`)
- Must include the `FILE:` prefix per Kerberos specification
- Stripped for `klist -k` commands using: `${KRB5_KTNAME#FILE:}`
- Allows customizing where keytab is located for volume sharing
- Referenced in scripts as: `KRB5_KEYTAB_FILE="${KRB5_KTNAME#FILE:}"`

#### Samba Configuration (smb.conf)

**KERBEROS_WORKGROUP**: NetBIOS workgroup/domain name (default: first component of KERBEROS_REALM)
- Required by `net ads join` command for AD domain joining
- Defaults to first component of realm using `${KERBEROS_REALM%%.*}`
- Example: `EXAMPLE.COM` → `EXAMPLE` (auto-derived)
- Must be set explicitly for multi-component realms (e.g., `WOODDALE.TEMPCO.COM` → `TEMPCO` not `WOODDALE`)
- Used to generate `/etc/samba/smb.conf` immediately before domain join (lines 288-304 in kerberos-entrypoint.sh)

**smb.conf Generation**: Created dynamically before `net ads join` command with:
- `workgroup`: Derived from KERBEROS_WORKGROUP or realm
- `realm`: Set to KERBEROS_REALM value
- `security = ads`: Enables Active Directory security model
- `kerberos method = system keytab`: Uses system-wide keytab for authentication
- `rpc_server:winbind = embedded`: Enables embedded RPC server within winbind process
- `rpc_daemon:winbindd = fork`: Uses forking model for concurrent RPC requests
- `hosts allow`: Dynamically generated list of internal networks plus localhost

### CIFS Service Principal Registration

**Problem**: Windows SMB clients request `cifs/hostname` tickets from AD, not `host/hostname` tickets. Without CIFS SPNs, SMB authentication fails even when the container is domain-joined.

**Solution**: Automatically register CIFS service principals immediately after successful domain join:

**Registration Process** (lines 316-333 in kerberos-entrypoint.sh):
1. Execute `net ads setspn add cifs/hostname.domain.com` for FQDN form
2. Execute `net ads setspn add cifs/HOSTNAME` for short hostname form
3. Verify SPNs registered in AD using `net ads setspn list`
4. Verify CIFS principals appear in final keytab after creation

**Exit Code**: 8 if CIFS SPN registration fails or CIFS principals missing from keytab

**Persistence**: CIFS SPNs remain registered in AD across keytab refreshes. The refresh script (lines 35-57 in kerberos-refresh.sh) includes defensive verification:
- Checks if CIFS SPNs still exist in AD before each refresh
- Re-registers them if missing (handles manual AD changes or account recreation)
- Verifies CIFS principals in refreshed keytab

This ensures SMB/CIFS authentication never silently breaks due to missing service principals.

### Winbind Proxy for Multi-Container SMB Deployments

**Problem**: In Docker deployments with isolated internal networks (`internal: true`), SMB containers cannot reach AD domain controllers to query user/group information for authorization decisions.

**Solution**: The kerberos container exposes its winbind daemon as a proxy, allowing isolated SMB containers to query AD indirectly through the kerberos container.

**Architecture**:
```
External Network (AD Domain Controllers)
           ↑
           │ (AD queries)
    [Kerberos Container]
      - winbind daemon
      - Unix socket: /var/run/samba/winbindd/pipe
      - socat TCP proxy: 0.0.0.0:9999
      - Has AD credentials
           │
           ↓ (TCP socket forwarding)
   Internal Network (isolated)
           ↓
    [SMB Containers]
      - socat client creates local Unix socket
      - Forwards to kerberos:9999
      - No direct AD access
      - No AD credentials needed
```

**Automatic Network Detection** (lines 245-286 in kerberos-entrypoint.sh):

The container automatically identifies internal (isolated) networks using connectivity-based detection:

1. **Enumerate interfaces**: Lists all non-loopback network interfaces via `ip -o -4 addr show`
2. **Calculate network addresses**: Uses bitwise operations to compute network CIDR from IP/netmask (supports any subnet size: /8, /16, /24, /32, etc.)
3. **Test external connectivity**: Pings 8.8.8.8 (Google DNS) from each interface
4. **Classify networks**:
   - Cannot reach 8.8.8.8 → Internal (isolated) network → Add to `hosts allow`
   - Can reach 8.8.8.8 → External network → Exclude from `hosts allow`
5. **Generate security config**: Build `hosts allow = 127.0.0.1 [internal networks]` directive

**Dependencies**: Requires `iputils-ping` package (added in line 61 of kerberos.dockerfile)

**Security Model**:
- Winbind RPC only accessible from localhost and detected internal networks
- External-facing networks automatically excluded from access
- No manual configuration required - adapts to any Docker network topology
- Exposes read-only AD queries (user/group lookups, SID mapping)
- Does NOT expose AD credentials or write operations

**Integration**: SMB containers sharing the same keytab volume automatically have access to the winbind proxy for AD lookups. See readme.md lines 302-462 for complete TCP proxy architecture, verification commands, and deployment examples.

#### TCP Socket Forwarding via socat

**Problem**: Winbind communicates exclusively via Unix domain sockets (`/var/run/samba/winbindd/pipe`). Docker named volumes cannot share Unix sockets between containers, and Samba's RPC server only exposes winbind via local pipes, not network sockets.

**Solution**: Use socat to bridge the Unix socket to TCP, enabling remote container access over Docker networks.

**Implementation** (`/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/scripts/winbind-proxy-start.sh`):

1. **Wait for winbind socket**: Poll for `/var/run/samba/winbindd/pipe` existence with 60-second timeout
   - Prevents race condition where proxy starts before winbind is ready
   - Exit code 1 if timeout reached (signals startup failure)

2. **Start TCP proxy**: Execute `socat TCP-LISTEN:$WINBIND_PROXY_PORT,fork,reuseaddr UNIX-CONNECT:/var/run/samba/winbindd/pipe`
   - `TCP-LISTEN:9999` - Binds to all interfaces (0.0.0.0:9999) for Docker network access
   - `fork` - Spawns new socat process per connection (concurrent clients supported)
   - `reuseaddr` - Sets SO_REUSEADDR socket option (enables immediate restart, prevents "address already in use" errors)
   - `UNIX-CONNECT` - Bidirectional forwarding to winbind Unix socket

3. **Process lifecycle**: Uses `exec` to replace wrapper process with socat (no extra process overhead)

**Container Integration** (line 91 in kerberos.dockerfile):
```dockerfile
CMD ["/bin/bash", "-c", "service winbind start && /usr/local/bin/winbind-proxy-start.sh & cron && tail -f /dev/null"]
```

The proxy starts after winbind but before the container blocks on `tail -f /dev/null`, ensuring winbind is ready before accepting remote connections.

**Port Configuration**:
- Default: 9999 (EXPOSE directive in kerberos.dockerfile line 84)
- Configurable via `WINBIND_PROXY_PORT` environment variable
- No port mapping required (internal Docker network communication)

**Client-Side Pattern**: Remote containers use socat to create a local Unix socket forwarding to the TCP proxy:
```bash
socat UNIX-LISTEN:/var/run/samba/winbindd/pipe,fork TCP:kerberos:9999 &
```

This makes remote winbind access transparent - standard tools like `wbinfo`, `getent passwd`, and `getent group` work without modification.

**Performance Characteristics**:
- Latency: ~0.5-2ms network overhead per query (vs ~0.01ms for local Unix socket)
- Concurrency: Fork model handles 500-1000 concurrent connections before degradation
- Memory: ~2-5MB for socat parent process, ~1-2MB per active connection
- Recovery: ~10 seconds downtime during kerberos container restart (remote containers reconnect automatically)

### Directory-Based Volume Sharing

**Problem**: Docker named volumes can only mount to directories, not individual files.

**Solution**: Use environment variables to relocate Kerberos files into a shared directory:
```yaml
environment:
  KRB5_CONFIG: /etc/krb5/krb5.conf
  KRB5_KTNAME: FILE:/etc/krb5/krb5.keytab
volumes:
  - kerberos-config:/etc/krb5  # Both files share same directory mount
```

This pattern enables:
- Multiple containers to share the same Kerberos configuration and keytab
- Clean separation between persistent state and shared configuration
- Read-only mounts in consuming containers to prevent accidental modifications

### Initialization Marker Location

**Location**: `/var/lib/kerberos/initialized`

The initialization marker moved from `/.initialized` to follow Linux Filesystem Hierarchy Standard (FHS):
- `/var/lib/` is for persistent state data
- Allows mounting `/var/lib/kerberos/` as a dedicated state volume
- Separates container state from shared credentials

See `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/readme.md` for complete volume configuration examples.

## Documentation

**Primary Documentation:** See `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/readme.md` for:
- Container architecture and lifecycle
- AD initialization flow (9-step process including CIFS SPN registration)
- Dynamic krb5.conf and smb.conf generation from KERBEROS_* environment variables
- Standard Kerberos environment variables (KRB5_CONFIG, KRB5_KTNAME)
- CIFS service principal registration for SMB/CIFS authentication
- Winbind proxy architecture for multi-container SMB deployments
- TCP socket forwarding via socat (architecture, client-side usage, verification commands)
- Network isolation detection and automatic security configuration
- Directory-based volume sharing pattern for multi-container deployments
- Keytab refresh mechanism (including CIFS SPN verification)
- Health monitoring via Docker HEALTHCHECK (keytab validity and AD connectivity verification)
- Environment variables and configuration reference (including KERBEROS_WORKGROUP and WINBIND_PROXY_PORT)
- Exit codes and troubleshooting
- Security best practices
- Docker Compose deployment examples

## Development Workflow

@sessions/CLAUDE.sessions.md

This file provides instructions for Claude Code for working in the cc-sessions framework.

### Git Merge Strategy

**IMPORTANT: This repository uses fast-forward merges only.**

When merging feature branches to main:
- Use `git merge --ff-only <branch-name>`
- DO NOT create merge commits with `--no-ff`
- Fast-forward merges keep a linear history
- If fast-forward is not possible, rebase the feature branch first

Example:
```bash
git checkout main
git merge --ff-only feature/my-feature
```

## Temporary Files Policy

**NEVER use `/tmp` for temporary files in this repository.**

When you need to create temporary files during development, testing, or agent operations:

1. **Use `sessions/temp/` directory** - Create this directory if it doesn't exist
2. **Use task-specific temp directories** - Create `sessions/tasks/[task-name]/temp/` for task-specific temporary files
3. **Clean up after yourself** - Remove temporary files/directories when no longer needed
4. **Add to .gitignore** - Ensure temp directories are in .gitignore (already configured)

**Rationale:**
- `/tmp` is system-wide and can conflict with other processes
- Repository-local temp directories keep all artifacts contained
- Easier to track and clean up temporary files
- Avoids permission issues in containerized environments
- Makes testing and debugging more predictable
