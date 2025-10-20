# Kerberos Container Project

This repository contains a containerized Active Directory integration service that handles Kerberos authentication for other services.

## Project Overview

This is a minimal Ubuntu 24.04-based container that:
- Joins an Active Directory domain
- Dynamically generates Kerberos configuration from environment variables
- Creates and maintains Kerberos keytabs for shared authentication
- Uses standard Kerberos environment variables (KRB5_CONFIG, KRB5_KTNAME) for configuration
- Provides keytabs to other services via directory-based volume mounts
- Automatically refreshes keytabs to stay ahead of AD password rotation

**Key Files:**
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/readme.md` - Complete container documentation including architecture, configuration, and troubleshooting
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/kerberos.dockerfile` - Container image definition
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/scripts/kerberos-entrypoint.sh` - Container initialization and AD join logic
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/scripts/kerberos-refresh.sh` - Keytab refresh mechanism (runs every 7 days)
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/scripts/publish_docker_image.sh` - Docker image publishing script

## Key Architectural Patterns

### Standard Kerberos Environment Variables

The container uses standard MIT Kerberos environment variables for configuration:

**KRB5_CONFIG**: Path to the krb5.conf file (default: `/etc/krb5.conf`)
- Allows customizing where krb5.conf is located
- Used for directory-based volume sharing (e.g., `/etc/krb5/krb5.conf`)
- Referenced in scripts as: `KRB5_CONFIG_FILE="${KRB5_CONFIG:-/etc/krb5.conf}"`

**KRB5_KTNAME**: Keytab location with type prefix (default: `FILE:/etc/krb5.keytab`)
- Must include the `FILE:` prefix per Kerberos specification
- Stripped for `klist -k` commands using: `${KRB5_KTNAME#FILE:}`
- Allows customizing where keytab is located for volume sharing
- Referenced in scripts as: `KRB5_KEYTAB_FILE="${KRB5_KTNAME#FILE:}"`

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
- AD initialization flow (8-step process)
- Dynamic krb5.conf generation from KERBEROS_* environment variables
- Standard Kerberos environment variables (KRB5_CONFIG, KRB5_KTNAME)
- Directory-based volume sharing pattern for multi-container deployments
- Keytab refresh mechanism
- Environment variables and configuration reference
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
