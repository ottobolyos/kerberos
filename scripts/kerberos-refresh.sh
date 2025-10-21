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

# Verify CIFS SPNs are still registered in AD, re-register if missing
echo "$(date): Verifying CIFS service principals ..."
fqdn=$(hostname -f)
short_hostname=$(hostname -s)

# Check if CIFS SPNs exist
if ! net ads setspn list "${short_hostname}" -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}" 2>/dev/null | grep -q "cifs/"; then
	echo "$(date): CIFS SPNs missing, re-registering ..."

	if ! net ads setspn add "cifs/${fqdn}" -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}"; then
		echo "$(date): ERROR: Failed to register CIFS SPN for FQDN (cifs/${fqdn})" 1>&2
		exit 1
	fi
	echo "$(date): Re-registered: cifs/${fqdn}"

	if ! net ads setspn add "cifs/${short_hostname}" -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}"; then
		echo "$(date): ERROR: Failed to register CIFS SPN for short hostname (cifs/${short_hostname})" 1>&2
		exit 1
	fi
	echo "$(date): Re-registered: cifs/${short_hostname}"
else
	echo "$(date): CIFS SPNs verified in AD"
fi

# Refresh keytab to pick up current keys (and any re-registered SPNs)
if ! net ads keytab create -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}"; then
	echo "$(date): ERROR: Failed to refresh keytab" 1>&2
	exit 1
fi

echo "$(date): Keytab refreshed successfully"
klist -k "$KRB5_KEYTAB_FILE"

# Verify CIFS principals are in the refreshed keytab
if ! klist -k "$KRB5_KEYTAB_FILE" | grep -q "cifs/"; then
	echo "$(date): ERROR: CIFS principals missing from keytab after refresh" 1>&2
	exit 1
fi

exit 0
