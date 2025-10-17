#!/usr/bin/env bash

# Kerberos container entrypoint
# Joins Active Directory and exports keytab for shared authentication
#
# Dependencies:
# - bash
# - coreutils (cat, touch)
# - realmd (realm)
# - samba-common-bin (net)
# - krb5-user (klist)
#
# Exit codes:
# 0 - Success
# 1 - Unknown error
# 2 - Required variables not defined
# 3 - Failed to discover realm
# 4 - Failed to join realm
# 5 - Failed to join domain
# 6 - Failed to register DNS entry
# 7 - Failed to create keytab

set -euo pipefail

INITIALIZED='/.initialized'

echo '################################################################################'
echo '# Kerberos Container for Shared Authentication'
echo '################################################################################'

if [ ! -f "$INITIALIZED" ]; then
	echo '>> CONTAINER: starting initialization'

	# Check whether the required variables are defined
	if [ -z "${AD_ADMIN_PASS-}" ] || [ -z "${AD_ADMIN_USER-}" ] || [ -z "${SAMBA_GLOBAL_CONFIG_realm-}" ]; then
		echo 'ERROR: AD: $AD_ADMIN_PASS, $AD_ADMIN_USER and $SAMBA_GLOBAL_CONFIG_realm must be defined.' 1>&2
		exit 2
	fi

	echo ">> AD: Checking if the ${SAMBA_GLOBAL_CONFIG_realm} realm can be discovered ..."

	if ! realm --install / -v discover "${SAMBA_GLOBAL_CONFIG_realm}"; then
		echo "ERROR: AD: Failed to discover the ${SAMBA_GLOBAL_CONFIG_realm} realm." 1>&2
		exit 3
	fi

	echo ">> AD: Joining the ${SAMBA_GLOBAL_CONFIG_realm} realm ..."
	if ! realm_join_result="$(realm --install / join "${SAMBA_GLOBAL_CONFIG_realm}" -U "${AD_ADMIN_USER}" <<< "${AD_ADMIN_PASS}")"; then
		if [ "$realm_join_result" = 'Already joined.' ]; then
			:
		fi
	fi
	realm --install / join "${SAMBA_GLOBAL_CONFIG_realm}" -U "${AD_ADMIN_USER}" <<< "${AD_ADMIN_PASS}" || true

	# Check whether we have successfully joined the realm
	is_realm_configured="$(realm --install / -v list "${SAMBA_GLOBAL_CONFIG_realm}" 2> /dev/null | grep -Po 'configured: \K.*')"

	if [ "$?" != 0 ] || [ "$is_realm_configured" = 'no' ]; then
		echo "ERROR: AD: Failed to join the ${SAMBA_GLOBAL_CONFIG_realm} realm." 1>&2
		exit 4
	fi

	echo ">> AD: Joining the ${SAMBA_GLOBAL_CONFIG_realm,,} domain ..."
	net ads join -U"${AD_ADMIN_USER}%${AD_ADMIN_PASS}"

	# Check whether we have successfully joined the domain
	if ! net ads info &> /dev/null; then
		echo "ERROR: AD: Failed to join the ${SAMBA_GLOBAL_CONFIG_realm} domain." 1>&2
		exit 5
	fi

	# Register DNS entry
	if [ -n "${HOST_IP-}" ] && [ -n "${HOST_HOSTNAME-}" ]; then
		echo ">> AD: Registering host DNS entry: ${HOST_HOSTNAME} -> ${HOST_IP}"
		if ! net ads dns register "${HOST_HOSTNAME}" "${HOST_IP}" -U"${AD_ADMIN_USER}%${AD_ADMIN_PASS}"; then
			echo "ERROR: AD: Failed to register DNS entry for host (${HOST_HOSTNAME} -> ${HOST_IP}) to Active Directory." 1>&2
			exit 6
		fi
	else
		if [ -n "${HOST_IP-}" ] || [ -n "${HOST_HOSTNAME-}" ]; then
			echo "WARNING: AD: HOST_IP and HOST_HOSTNAME must both be set or both be unset. Falling back to container DNS registration." 1>&2
		fi
		echo ">> AD: Registering container DNS entry"
		if ! net ads dns register -U"${AD_ADMIN_USER}%${AD_ADMIN_PASS}"; then
			echo "ERROR: AD: Failed to register DNS entry for the container to Active Directory." 1>&2
			exit 6
		fi
	fi

	echo '>> AD: Creating Kerberos keytab ...'
	if ! net ads keytab create -U"${AD_ADMIN_USER}%${AD_ADMIN_PASS}"; then
		echo 'ERROR: AD: Failed to create Kerberos keytab.' 1>&2
		exit 7
	fi

	echo '>> AD: Verifying keytab contents ...'
	klist -k /etc/krb5.keytab

	echo '>> AD: Setting up keytab refresh cron job (every 7 days) ...'
	echo "0 0 */7 * * /usr/local/bin/kerberos-refresh.sh >> /var/log/keytab-refresh.log 2>&1" | crontab -

	echo '>> AD: Successfully configured'

	touch "$INITIALIZED"
else
	echo '>> CONTAINER: Already initialized - verifying AD membership'

	if ! net ads testjoin &> /dev/null; then
		echo 'WARNING: AD membership test failed - container may need re-initialization' 1>&2
	else
		echo '>> AD: Membership verified'
	fi
fi

echo '>> CMD: Starting services'
exec "$@"
