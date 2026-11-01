#!/bin/sh
# Dashboards are stored without the project ID, which is filled in at startup.
set -eu

: "${GCP_PROJECT:?GCP_PROJECT must be set}"

mkdir -p /tmp/housefull-dashboards
sed "s/__PROJECT__/$GCP_PROJECT/g" /etc/grafana/housefull-dashboards/housefull.json \
  > /tmp/housefull-dashboards/housefull.json

# Nobody can log in, so this random password is never used or stored.
GF_SECURITY_ADMIN_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
export GF_SECURITY_ADMIN_PASSWORD

exec /run.sh
