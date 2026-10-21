scope: hagod
namespace: /hagod/
name: ${PG_NAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${PG_NAME}:8008

etcd3:
  hosts: etcd1:2379,etcd2:2379,etcd3:2379

bootstrap:
  dcs:
    ttl: 30                       # leader key lifetime; failover starts when it expires
    loop_wait: 10                 # how often every node runs its HA loop
    retry_timeout: 10             # how long to retry DCS/PG operations before giving up
    maximum_lag_on_failover: 1048576   # a replica further behind than this (bytes) cannot be promoted
    synchronous_mode: false       # drill 05 turns this on
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: "on"       # required by pg_rewind unless data checksums are on
        archive_mode: "on"
        archive_command: "cmp -s %p /archive/%f || { cp %p /archive/%f.tmp && mv /archive/%f.tmp /archive/%f; }"
        restore_command: "cp /archive/%f %p"
        archive_timeout: 60
        max_connections: 200
        log_min_duration_statement: 500
        log_checkpoints: "on"
        log_lock_waits: "on"
        log_connections: "off"
        shared_preload_libraries: pg_stat_statements
        track_io_timing: "on"
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - local all all trust
    - host replication replicator 0.0.0.0/0 md5
    - host all all 0.0.0.0/0 md5

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${PG_NAME}:5432
  data_dir: /var/lib/postgresql/data/pgdata
  bin_dir: /usr/lib/postgresql/17/bin
  pgpass: /tmp/pgpass
  authentication:
    superuser:   {username: postgres,   password: hagod-super}
    replication: {username: replicator, password: hagod-repl}
  parameters:
    unix_socket_directories: /tmp

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
