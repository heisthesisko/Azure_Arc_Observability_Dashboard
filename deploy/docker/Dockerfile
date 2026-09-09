FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

ARG AZURE_CLI_VERSION=

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release \
    && mkdir -p /etc/apt/keyrings \
    && curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
       | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
    && chmod go+r /etc/apt/keyrings/microsoft.gpg \
    && AZ_DIST="$(lsb_release -cs)" \
    && printf "Types: deb\nURIs: https://packages.microsoft.com/repos/azure-cli/\nSuites: %s\nComponents: main\nArchitectures: amd64\nSigned-by: /etc/apt/keyrings/microsoft.gpg\n" "$AZ_DIST" \
       > /etc/apt/sources.list.d/azure-cli.sources \
    && apt-get update \
    && if [ -n "$AZURE_CLI_VERSION" ]; then \
         apt-get install -y --no-install-recommends "azure-cli=${AZURE_CLI_VERSION}-1~${AZ_DIST}"; \
       else \
         apt-get install -y --no-install-recommends azure-cli; \
       fi \
    && apt-get purge -y --auto-remove curl gnupg lsb-release \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/arc-dashboard
COPY app/ ./
COPY entrypoint.sh /usr/local/bin/arc-dashboard-entrypoint

RUN chmod 0555 /usr/local/bin/arc-dashboard-entrypoint \
    && chmod -R a=rX /opt/arc-dashboard \
    && mkdir -p /var/lib/arc-dashboard \
    && chgrp -R 0 /var/lib/arc-dashboard \
    && chmod -R g=u /var/lib/arc-dashboard

ENV ARC_DASHBOARD_DATA_ROOT=/var/lib/arc-dashboard \
    ARC_DASHBOARD_BIND_ADDRESS=0.0.0.0 \
    ARC_DASHBOARD_PORT=8766

EXPOSE 8766
VOLUME ["/var/lib/arc-dashboard"]
USER 10001

ENTRYPOINT ["/usr/local/bin/arc-dashboard-entrypoint"]
