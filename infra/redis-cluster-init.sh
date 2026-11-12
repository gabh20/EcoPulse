#!/bin/sh
set -eu
if redis-cli -h redis-1 cluster info | grep -q 'cluster_state:ok'; then
  echo 'Cluster Redis já configurado.'
  exit 0
fi
redis-cli --cluster create redis-1:6379 redis-2:6379 redis-3:6379 redis-4:6379 redis-5:6379 redis-6:6379 --cluster-replicas 1 --cluster-yes
