FROM postgres:16-bookworm

ARG PATRONI_VERSION=4.1.4

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-pip curl jq \
    && pip3 install --break-system-packages --no-cache-dir \
       "patroni[etcd3,psycopg2-binary]==${PATRONI_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/patroni-entrypoint
RUN chmod 0755 /usr/local/bin/patroni-entrypoint

ENTRYPOINT ["/usr/local/bin/patroni-entrypoint"]
CMD ["/etc/patroni.yml"]
