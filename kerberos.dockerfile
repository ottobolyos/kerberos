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
