# Kerberos Container Project

This repository contains a containerized Active Directory integration service that handles Kerberos authentication for other services.

## Project Overview

This is a minimal Ubuntu 24.04-based container that:
- Joins an Active Directory domain
- Creates and maintains Kerberos keytabs for shared authentication
- Provides keytabs to other services via volume mounts
- Automatically refreshes keytabs to stay ahead of AD password rotation

**Key Files:**
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/readme.md` - Complete container documentation including architecture, configuration, and troubleshooting
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/kerberos.dockerfile` - Container image definition
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/scripts/kerberos-entrypoint.sh` - Container initialization and AD join logic
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/scripts/kerberos-refresh.sh` - Keytab refresh mechanism (runs every 7 days)
- `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/scripts/publish_docker_image.sh` - Docker image publishing script

## Documentation

**Primary Documentation:** See `/run/media/ts/root/home/ts/git/mriiot/otto/kerberos/readme.md` for:
- Container architecture and lifecycle
- AD initialization flow (8-step process)
- Keytab refresh mechanism
- Environment variables and configuration
- Exit codes and troubleshooting
- Security best practices
- Docker Compose deployment examples

## Development Workflow

@sessions/CLAUDE.sessions.md

This file provides instructions for Claude Code for working in the cc-sessions framework.

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
