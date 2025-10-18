# Kerberos Container for Active Directory Integration
#
# This container provides shared Kerberos authentication for services that need
# to authenticate against Active Directory. It handles AD domain joining, keytab
# creation, and automated keytab refresh.
#
# Documentation: See /run/media/ts/root/home/ts/git/mriiot/otto/kerberos/readme.md for:
# - Container architecture and lifecycle
# - Environment variables and configuration
# - Docker Compose deployment examples
# - Security best practices and troubleshooting
#
# Key Features:
# - Minimal Ubuntu 24.04 base (only AD client packages, not full Samba server)
# - "Join once, maintain forever" pattern with initialization marker
# - Automated keytab refresh every 7 days via cron
# - Supports both host and container DNS registration modes
#
# Required Environment Variables:
# - AD_ADMIN_USER: Active Directory administrator username
# - AD_ADMIN_PASS: Password for the AD admin account
# - SAMBA_GLOBAL_CONFIG_realm: AD realm/domain (e.g., EXAMPLE.COM)
#
# Optional Environment Variables:
# - HOST_IP: Docker host IP for DNS registration
# - HOST_HOSTNAME: Docker host hostname for DNS registration

FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install minimal AD/Kerberos packages (NOT full Samba server)
RUN apt-get update && apt-get install -y \
    realmd \
    sssd-ad \
    sssd-tools \
    adcli \
    krb5-user \
    winbind \
    samba-common-bin \
    cron \
    && rm -rf /var/lib/apt/lists/*

# Create directory for Samba private data
RUN mkdir -p /var/lib/samba/private

# Copy entrypoint script
COPY scripts/kerberos-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Copy keytab refresh cron script
COPY scripts/kerberos-refresh.sh /usr/local/bin/kerberos-refresh.sh
RUN chmod +x /usr/local/bin/kerberos-refresh.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash", "-c", "service winbind start && cron && tail -f /dev/null"]
