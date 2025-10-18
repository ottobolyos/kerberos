#!/usr/bin/env bash

# Kerberos container entrypoint
# Joins Active Directory and exports keytab for shared authentication
#
# Documentation: See /run/media/ts/root/home/ts/git/mriiot/otto/kerberos/readme.md for:
# - Complete AD initialization flow (8 steps)
# - Environment variables reference
# - Troubleshooting guides
# - Container lifecycle and architecture
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

# ============================================================================
# krb5.conf Generation from Environment Variables
# ============================================================================

generate_krb5_conf() {
	local realm="${KERBEROS_REALM:-}"
	# Default domain to lowercase realm if not specified (e.g., EXAMPLE.COM -> example.com)
	local domain="${KERBEROS_DOMAIN:-${realm,,}}"
	local kdc_servers="${KERBEROS_KDC_SERVERS:-}"

	# Validate required variables
	if [[ -z "$realm" ]]; then
		echo " ! ERROR: KERBEROS_REALM not defined" >&2
		return 1
	fi

	# Optional parameters with defaults
	local ticket_lifetime="${KERBEROS_TICKET_LIFETIME:-24h}"
	local renew_lifetime="${KERBEROS_RENEW_LIFETIME:-7d}"
	local dns_lookup_kdc="${KERBEROS_DNS_LOOKUP_KDC:-true}"
	local dns_lookup_realm="${KERBEROS_DNS_LOOKUP_REALM:-false}"
	local forwardable="${KERBEROS_FORWARDABLE:-true}"
	local rdns="${KERBEROS_RDNS:-false}"

	echo " + Generating /etc/krb5.conf from environment variables"

	cat > /etc/krb5.conf <<-EOF
		[domain_realm]
		.$domain = $realm
		$domain = $realm

		[libdefaults]
		default_ccache_name = FILE:/tmp/krb5cc_%{uid}
		default_realm = $realm
		dns_lookup_kdc = $dns_lookup_kdc
		dns_lookup_realm = $dns_lookup_realm
		forwardable = $forwardable
		pkinit_anchors = FILE:/etc/ssl/certs/ca-certificates.crt
		rdns = $rdns
		renew_lifetime = $renew_lifetime
		spake_preauth_groups = edwards25519
		ticket_lifetime = $ticket_lifetime
		udp_preference_limit = 0

		[logging]
		admin_server = FILE:/var/log/kadmind.log
		default = FILE:/var/log/krb5libs.log
		kdc = FILE:/var/log/krb5kdc.log

		[plugins]
		localauth = {
			enable_only = winbind
			module = winbind:/usr/lib/x86_64-linux-gnu/samba/krb5/winbind_krb5_locator.so
		}
	EOF

	# Only add [realms] section if KDC servers are explicitly specified
	if [[ -n "$kdc_servers" ]]; then
		cat >> /etc/krb5.conf <<-EOF

			[realms]
			$realm = {
				default_domain = $domain
		EOF

		# Add each KDC server
		for kdc in $kdc_servers; do
			printf '\t\t\tkdc = %s\n' "$kdc" >> /etc/krb5.conf
		done

		cat >> /etc/krb5.conf <<-EOF
			}
		EOF
	fi

	chmod 644 /etc/krb5.conf

	# Validate generated configuration
	if [[ ! -s /etc/krb5.conf ]]; then
		echo " ! ERROR: Generated krb5.conf is empty or missing" >&2
		return 1
	fi

	echo " + krb5.conf generated successfully"
}

# Generate krb5.conf on every container start
# This ensures the config is always in sync with environment variables
# and allows realmd to modify it during initialization
generate_krb5_conf

if [ ! -f "$INITIALIZED" ]; then
	echo '>> CONTAINER: starting initialization'

	# Check whether the required variables are defined
	if [ -z "${KERBEROS_ADMIN_PASSWORD-}" ] || [ -z "${KERBEROS_ADMIN_USER-}" ] || [ -z "${KERBEROS_REALM-}" ]; then
		# shellcheck disable=SC2016 # Single quotes intentional to show literal variable names in error message
		echo 'ERROR: AD: $KERBEROS_ADMIN_PASSWORD, $KERBEROS_ADMIN_USER and $KERBEROS_REALM must be defined.' 1>&2
		exit 2
	fi

	echo ">> AD: Checking if the ${KERBEROS_REALM} realm can be discovered ..."

	if ! realm --install / -v discover "${KERBEROS_REALM}"; then
		echo "ERROR: AD: Failed to discover the ${KERBEROS_REALM} realm." 1>&2
		exit 3
	fi

	echo ">> AD: Joining the ${KERBEROS_REALM} realm ..."
	if ! realm_join_result="$(realm --install / join "${KERBEROS_REALM}" -U "${KERBEROS_ADMIN_USER}" <<< "${KERBEROS_ADMIN_PASSWORD}")"; then
		if [ "$realm_join_result" = 'Already joined.' ]; then
			:
		fi
	fi
	realm --install / join "${KERBEROS_REALM}" -U "${KERBEROS_ADMIN_USER}" <<< "${KERBEROS_ADMIN_PASSWORD}" || true

	# Check whether we have successfully joined the realm
	if ! is_realm_configured="$(realm --install / -v list "${KERBEROS_REALM}" 2> /dev/null | grep -Po 'configured: \K.*')" || [ "$is_realm_configured" = 'no' ]; then
		echo "ERROR: AD: Failed to join the ${KERBEROS_REALM} realm." 1>&2
		exit 4
	fi

	echo ">> AD: Joining the ${KERBEROS_REALM,,} domain ..."
	net ads join -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}"

	# Check whether we have successfully joined the domain
	if ! net ads info &> /dev/null; then
		echo "ERROR: AD: Failed to join the ${KERBEROS_REALM} domain." 1>&2
		exit 5
	fi

	# Register DNS entry
	if [ -n "${HOST_IP-}" ] && [ -n "${HOST_HOSTNAME-}" ]; then
		echo ">> AD: Registering host DNS entry: ${HOST_HOSTNAME} -> ${HOST_IP}"
		if ! net ads dns register "${HOST_HOSTNAME}" "${HOST_IP}" -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}"; then
			echo "ERROR: AD: Failed to register DNS entry for host (${HOST_HOSTNAME} -> ${HOST_IP}) to Active Directory." 1>&2
			exit 6
		fi
	else
		if [ -n "${HOST_IP-}" ] || [ -n "${HOST_HOSTNAME-}" ]; then
			echo "WARNING: AD: HOST_IP and HOST_HOSTNAME must both be set or both be unset. Falling back to container DNS registration." 1>&2
		fi
		echo ">> AD: Registering container DNS entry"
		if ! net ads dns register -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}"; then
			echo "ERROR: AD: Failed to register DNS entry for the container to Active Directory." 1>&2
			exit 6
		fi
	fi

	echo '>> AD: Creating Kerberos keytab ...'
	if ! net ads keytab create -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}"; then
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
