#!/usr/bin/env bash

# Kerberos container entrypoint
# Joins Active Directory and exports keytab for shared authentication
#
# Documentation: See /run/media/ts/root/home/ts/git/mriiot/otto/kerberos/readme.md for:
# - Complete AD initialization flow (9 steps)
# - Environment variables reference
# - Troubleshooting guides
# - Container lifecycle and architecture
#
# Dependencies:
# - bash
# - coreutils (cat, touch)
# - realmd (realm)
# - samba-common-bin (net)
# - krb5-user (klist, kinit, kdestroy)
# - dnsutils (nslookup)
#
# Exit codes:
# 0 - Success
# 1 - Unknown error
# 2 - Required variables not defined
# 3 - Failed to discover realm or DNS verification failed
# 4 - Failed credential validation or realm join
# 5 - Failed to join domain
# 6 - Failed to register DNS entry
# 7 - Failed to create keytab
# 8 - Failed to register CIFS service principal names

set -euo pipefail

# Set defaults for Kerberos environment variables
KRB5_KTNAME="${KRB5_KTNAME:-FILE:/etc/krb5.keytab}"

# Define file path variables
INITIALIZED='/var/lib/kerberos/initialized'
KRB5_CONFIG_FILE="${KRB5_CONFIG:-/etc/krb5.conf}"
KRB5_KEYTAB_FILE="${KRB5_KTNAME#FILE:}"

# Ensure all required directories exist
mkdir -p /var/lib/kerberos
mkdir -p "$(dirname "$KRB5_CONFIG_FILE")"
mkdir -p "$(dirname "$KRB5_KEYTAB_FILE")"

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

	echo " + Generating $KRB5_CONFIG_FILE from environment variables"

	cat > "$KRB5_CONFIG_FILE" <<-EOF
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
		cat >> "$KRB5_CONFIG_FILE" <<-EOF

			[realms]
			$realm = {
				default_domain = $domain
		EOF

		# Add each KDC server
		for kdc in $kdc_servers; do
			printf '\t\t\tkdc = %s\n' "$kdc" >> "$KRB5_CONFIG_FILE"
		done

		cat >> "$KRB5_CONFIG_FILE" <<-EOF
			}
		EOF
	fi

	chmod 644 "$KRB5_CONFIG_FILE"

	# Validate generated configuration
	if [[ ! -s "$KRB5_CONFIG_FILE" ]]; then
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

	# DNS verification - helps distinguish DNS issues from authentication issues
	echo ">> AD: Verifying DNS resolution for ${KERBEROS_REALM} ..."
	if dns_result=$(nslookup "${KERBEROS_REALM}" 2>&1); then
		echo "   Resolved successfully"
		echo "${dns_result}" | grep -A 2 "^Name:"
	else
		echo "ERROR: AD: Cannot resolve ${KERBEROS_REALM} via DNS" 1>&2
		echo "       DNS lookup output:" 1>&2
		# shellcheck disable=SC2001  # Indenting each line of multi-line output - sed is cleaner than parameter expansion
		sed 's/^/       /' <<< "${dns_result}" 1>&2
		echo "" 1>&2
		echo "       Configured DNS servers:" 1>&2
		# shellcheck disable=SC2001  # Indenting each line of multi-line output - sed is cleaner than parameter expansion
		grep -E '^nameserver' /etc/resolv.conf | sed 's/^/       /' 1>&2 || echo "       (none found)" 1>&2
		exit 3
	fi

	# Credential validation - test authentication before attempting realm join
	echo ">> AD: Validating credentials with Kerberos KDC ..."
	if ! kinit_output="$(echo "${KERBEROS_ADMIN_PASSWORD}" | kinit "${KERBEROS_ADMIN_USER}@${KERBEROS_REALM}" 2>&1)"; then
		echo "ERROR: AD: Credential validation failed" 1>&2
		echo "       Kerberos error: ${kinit_output}" 1>&2
		echo "       Check that KERBEROS_ADMIN_USER and KERBEROS_ADMIN_PASSWORD are correct" 1>&2
		exit 4
	fi
	echo ">> AD: Credentials validated successfully"

	# Clean up the test ticket
	if ! kdestroy 2>/dev/null; then
		echo "   Note: No credential cache to clean up (this is fine)" 1>&2
	fi

	echo ">> AD: Joining the ${KERBEROS_REALM} realm ..."

	# Capture both stdout and stderr with verbose output
	if realm_join_output="$(realm --install / -v join "${KERBEROS_REALM}" -U "${KERBEROS_ADMIN_USER}" <<< "${KERBEROS_ADMIN_PASSWORD}" 2>&1)"; then
		echo ">> AD: Realm join succeeded"
		echo "${realm_join_output}"
	else
		realm_join_exit_code=$?

		# Check if the "failure" was actually "Already joined" (which is acceptable)
		if echo "${realm_join_output}" | grep -q "Already joined"; then
			echo ">> AD: Already joined to realm (continuing)"
		else
			# Real failure - dump diagnostics
			echo "ERROR: AD: Realm join failed (exit code ${realm_join_exit_code})" 1>&2
			echo "       Realm join output:" 1>&2
			echo "${realm_join_output}" 1>&2
			echo "" 1>&2
			echo "       Recent realmd logs:" 1>&2
			if command -v journalctl &>/dev/null; then
				journalctl -u realmd --no-pager -n 20 1>&2 || echo "       (realmd logs unavailable)" 1>&2
			else
				echo "       (journalctl not available in this container)" 1>&2
			fi
			exit 4
		fi
	fi

	# Verify realm is properly configured
	echo ">> AD: Verifying realm configuration ..."
	realm_list_output="$(realm --install / list "${KERBEROS_REALM}" 2>&1)"
	realm_list_exit_code=$?

	if [ "$realm_list_exit_code" != 0 ]; then
		echo "ERROR: AD: Cannot query realm configuration" 1>&2
		echo "       ${realm_list_output}" 1>&2
		exit 4
	fi

	is_realm_configured="$(echo "${realm_list_output}" | grep -Po 'configured: \K.*')"

	if [ "$is_realm_configured" = 'no' ]; then
		echo "ERROR: AD: Realm is not configured" 1>&2
		echo "       Full realm status:" 1>&2
		echo "${realm_list_output}" 1>&2
		exit 4
	fi

	echo ">> AD: Realm configuration verified (configured: ${is_realm_configured})"

	# Derive workgroup from realm if not explicitly set
	# Example: WOODDALE.TEMPCO.COM -> WOODDALE (but user can override with KERBEROS_WORKGROUP=TEMPCO)
	realm_first_component="${KERBEROS_REALM%%.*}"
	workgroup="${KERBEROS_WORKGROUP:-$realm_first_component}"

	echo ">> AD: Generating /etc/samba/smb.conf for domain join ..."
	mkdir -p /etc/samba
	cat > /etc/samba/smb.conf <<-EOF
	[global]
	   workgroup = $workgroup
	   realm = ${KERBEROS_REALM}
	   security = ads
	   kerberos method = system keytab
	EOF
	chmod 644 /etc/samba/smb.conf
	echo "   Workgroup: $workgroup"
	echo "   Realm: ${KERBEROS_REALM}"

	echo ">> AD: Joining the ${KERBEROS_REALM,,} domain ..."
	net ads join -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}"

	# Check whether we have successfully joined the domain
	if ! net ads info &> /dev/null; then
		echo "ERROR: AD: Failed to join the ${KERBEROS_REALM} domain." 1>&2
		exit 5
	fi

	# Register CIFS service principal names for SMB/CIFS authentication
	echo '>> AD: Registering CIFS service principals ...'
	fqdn=$(hostname -f)
	short_hostname=$(hostname -s)

	if ! net ads setspn add "cifs/${fqdn}" -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}"; then
		echo "ERROR: AD: Failed to register CIFS SPN for FQDN (cifs/${fqdn})." 1>&2
		exit 8
	fi
	echo "   Registered: cifs/${fqdn}"

	if ! net ads setspn add "cifs/${short_hostname}" -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}"; then
		echo "ERROR: AD: Failed to register CIFS SPN for short hostname (cifs/${short_hostname})." 1>&2
		exit 8
	fi
	echo "   Registered: cifs/${short_hostname}"

	echo '>> AD: Verifying registered SPNs ...'
	net ads setspn list "${short_hostname}" -U"${KERBEROS_ADMIN_USER}%${KERBEROS_ADMIN_PASSWORD}"

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
	klist -k "$KRB5_KEYTAB_FILE"

	echo '>> AD: Verifying CIFS principals in keytab ...'
	if klist -k "$KRB5_KEYTAB_FILE" | grep -q "cifs/"; then
		echo '   ✓ CIFS principals found in keytab'
	else
		echo 'ERROR: AD: CIFS principals missing from keytab after registration.' 1>&2
		exit 8
	fi

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
