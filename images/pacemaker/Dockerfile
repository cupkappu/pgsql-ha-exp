FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       systemd systemd-sysv dbus \
       corosync pacemaker pacemaker-cli-utils pcs \
       resource-agents-base resource-agents-paf \
       postgresql-16 postgresql-client-16 \
       docker.io \
       curl jq iproute2 iputils-ping procps netcat-openbsd \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl disable postgresql.service \
    && systemctl mask getty@.service console-getty.service systemd-logind.service \
    && systemctl enable corosync.service pacemaker.service

COPY fence_peer_docker /usr/sbin/fence_peer_docker
COPY cluster-entrypoint.sh /usr/local/sbin/cluster-entrypoint
RUN chmod 0755 /usr/sbin/fence_peer_docker /usr/local/sbin/cluster-entrypoint

STOPSIGNAL SIGTERM
CMD ["/usr/local/sbin/cluster-entrypoint"]
