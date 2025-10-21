#!/usr/bin/env bash

# Winbind TCP Proxy Startup Script
# Exposes winbind Unix socket as TCP listener for remote container access
#
# Documentation: See /run/media/ts/root/home/ts/git/mriiot/otto/kerberos/readme.md for:
# - Winbind proxy architecture and multi-container integration
# - TCP socket forwarding via socat
# - Verification commands and troubleshooting
#
# Dependencies:
# - bash
# - socat
# - winbind (must be running and have created Unix socket)
#
# Exit codes:
# 0 - Success (socat exits normally)
# Non-zero - socat error (connection refused, port in use, etc.)

set -euo pipefail

WINBIND_SOCKET="/var/run/samba/winbindd/pipe"
TCP_PORT="${WINBIND_PROXY_PORT:-9999}"

echo ">> Winbind Proxy: Waiting for winbind socket to be created ..."

# Wait for winbind daemon to create its Unix socket (up to 60 seconds)
TIMEOUT=60
ELAPSED=0
while [ ! -S "$WINBIND_SOCKET" ]; do
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo ">> Winbind Proxy: ERROR - Winbind socket not found after ${TIMEOUT}s" 1>&2
        exit 1
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

echo ">> Winbind Proxy: Winbind socket found at $WINBIND_SOCKET"
echo ">> Winbind Proxy: Starting TCP proxy on port $TCP_PORT ..."

# Start socat to forward TCP connections to Unix socket
# - TCP-LISTEN:9999 - Listen on TCP port 9999 (all interfaces)
# - fork - Create new process for each connection (concurrent clients)
# - reuseaddr - Allow immediate restart (SO_REUSEADDR socket option)
# - UNIX-CONNECT - Connect to winbind Unix socket for each TCP connection
exec socat "TCP-LISTEN:$TCP_PORT,fork,reuseaddr" "UNIX-CONNECT:$WINBIND_SOCKET"
