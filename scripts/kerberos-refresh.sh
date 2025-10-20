#!/usr/bin/env bash

# Kerberos keytab refresh script
# Runs periodically to refresh keytab before AD password rotation (30 days)
#
# Documentation: See /run/media/ts/root/home/ts/git/mriiot/otto/kerberos/readme.md for:
# - Keytab refresh mechanism and rationale
# - Cron schedule configuration (7-day cycle)
# - Troubleshooting keytab refresh failures
#
# Dependencies:
# - bash
# - samba-common-bin (net)
# - krb5-user (klist)
#
# Exit codes:
# 0 - Success
# 1 - Failed to refresh keytab

set -euo pipefail

# Set defaults for Kerberos environment variables
KRB5_KTNAME="${KRB5_KTNAME:-FILE:/etc/krb5.keytab}"

# Define file path variables
KRB5_KEYTAB_FILE="${KRB5_KTNAME#FILE:}"

echo "$(date): Starting keytab refresh"

if [ -z "${KERBEROS_ADMIN_PASSWORD-}" ] || [ -z "${KERBEROS_ADMIN_USER-}" ]; then
	echo "$(date): ERROR: KERBEROS_ADMIN_PASSWORD and KERBEROS_ADMIN_USER must be defined" 1>&2
	exit 1
fi

if ! net ads keytab create -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}"; then
	echo "$(date): ERROR: Failed to refresh keytab" 1>&2
	exit 1
fi

echo "$(date): Keytab refreshed successfully"
klist -k "$KRB5_KEYTAB_FILE"

exit 0
