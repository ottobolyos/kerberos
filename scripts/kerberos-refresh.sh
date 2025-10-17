#!/usr/bin/env bash

# Kerberos keytab refresh script
# Runs periodically to refresh keytab before AD password rotation (30 days)
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

echo "$(date): Starting keytab refresh"

if [ -z "${AD_ADMIN_PASS-}" ] || [ -z "${AD_ADMIN_USER-}" ]; then
	echo "$(date): ERROR: AD_ADMIN_PASS and AD_ADMIN_USER must be defined" 1>&2
	exit 1
fi

if ! net ads keytab create -U"${AD_ADMIN_USER}%${AD_ADMIN_PASS}"; then
	echo "$(date): ERROR: Failed to refresh keytab" 1>&2
	exit 1
fi

echo "$(date): Keytab refreshed successfully"
klist -k /etc/krb5.keytab

exit 0
