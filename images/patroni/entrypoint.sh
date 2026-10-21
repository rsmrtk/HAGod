#!/bin/bash
# Renders /tmp/patroni.yml from the template and starts Patroni.
set -e
envsubst < /etc/patroni/patroni.yml.tpl > /tmp/patroni.yml
chmod 700 /var/lib/postgresql/data 2>/dev/null || true
# a short alias so `patronictl list` works without -c inside the container
mkdir -p ~/.config/patroni && cp /tmp/patroni.yml ~/.config/patroni/patronictl.yaml
exec patroni /tmp/patroni.yml
