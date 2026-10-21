# Postgres 17 + Patroni (etcd3 DCS). One image, three nodes.
FROM postgres:17

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv python3-pip gettext-base curl jq iproute2 procps iputils-ping less vim-tiny redis-tools dnsutils \
 && python3 -m venv /opt/patroni \
 && /opt/patroni/bin/pip install --no-cache-dir "patroni[etcd3]" psycopg2-binary \
 && rm -rf /var/lib/apt/lists/*

ENV PATH=/opt/patroni/bin:$PATH
COPY patroni.yml.tpl /etc/patroni/patroni.yml.tpl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
 && mkdir -p /var/lib/postgresql/data /archive /backup \
 && chown -R postgres:postgres /var/lib/postgresql /archive /backup

USER postgres
ENTRYPOINT ["/entrypoint.sh"]
