# Image of the HA labels sidecar of the Zabbix Helm chart. See README.md.
# The version of kubectl comes from the Alpine release. Dependabot updates the tag of the base image
FROM alpine:3.24

LABEL org.opencontainers.image.title="zabbix-server-ha-label-manager" \
      org.opencontainers.image.description="Sidecar of the Zabbix Helm chart that labels the Zabbix Server pods as active or standby HA nodes" \
      org.opencontainers.image.source="https://github.com/zabbix-community/helm-zabbix-image-ha-labels-sidecar" \
      org.opencontainers.image.licenses="Apache-2.0"

# hadolint ignore=DL3018
RUN apk add --no-cache kubectl && \
    kubectl version --client

COPY --chmod=0755 ha-label-manager.sh /script/ha-label-manager.sh

# Same user of the previous image, based on bitnami/kubectl
USER 1001
ENTRYPOINT ["/script/ha-label-manager.sh"]
