#!/usr/bin/env bash
# Runs on every boot of the VPN VM. Safe to run again.
set -euo pipefail

STATE=/var/lib/housefull-vpn
INNER_NET=housefull-private
WAG_IMAGE=wagvpn/wag:v9.1.12
GRAFANA_IMAGE=grafana/grafana:13.3.0

metadata() {
  curl -fsS -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/$1"
}

# A small VM needs swap to run Grafana comfortably.
if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
swapon -a

if ! command -v docker >/dev/null || ! command -v wg >/dev/null; then
  apt-get update
  apt-get install -y docker.io wireguard-tools unattended-upgrades
fi
systemctl enable --now docker unattended-upgrades

modprobe wireguard
sysctl -w net.ipv4.ip_forward=1

mkdir -p "$STATE/wag" "$STATE/grafana/datasources" "$STATE/grafana/dashboards-provider" "$STATE/grafana/dashboards"
chmod 700 "$STATE"

# Made here, so the VPN's private key never appears in Terraform state or logs.
if [ ! -f "$STATE/private.key" ]; then
  (umask 077 && wg genkey > "$STATE/private.key")
fi

EXTERNAL_IP="$(metadata network-interfaces/0/access-configs/0/external-ip)"
PRIVATE_KEY="$(cat "$STATE/private.key")"
sed -e "s|__EXTERNAL_IP__|$EXTERNAL_IP|" -e "s|__PRIVATE_KEY__|$PRIVATE_KEY|" \
  <(metadata attributes/wag-config) > "$STATE/wag/config.json"
chmod 600 "$STATE/wag/config.json"

metadata attributes/grafana-datasource > "$STATE/grafana/datasources/monitoring.yaml"
metadata attributes/grafana-provider > "$STATE/grafana/dashboards-provider/housefull.yaml"
metadata attributes/grafana-dashboard > "$STATE/grafana/dashboards/housefull.json"
GCP_PROJECT="$(metadata attributes/project)"

docker network inspect "$INNER_NET" >/dev/null 2>&1 ||
  docker network create --subnet 172.31.9.0/24 "$INNER_NET"

docker rm -f wag grafana >/dev/null 2>&1 || true

docker run -d --name wag --restart unless-stopped \
  --cap-add NET_ADMIN --device /dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  --network "$INNER_NET" --ip 172.31.9.2 \
  -p 53230:53230/udp -p 8081:8081/tcp \
  -v "$STATE/wag:/cfg" \
  "$WAG_IMAGE"

# No published ports: the only way in is through the VPN, after MFA.
docker run -d --name grafana --restart unless-stopped \
  --network "$INNER_NET" --ip 172.31.9.10 \
  -e GCP_PROJECT="$GCP_PROJECT" \
  -e GF_AUTH_ANONYMOUS_ENABLED=true \
  -e GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer \
  -e GF_AUTH_DISABLE_LOGIN_FORM=true \
  -e GF_AUTH_BASIC_ENABLED=false \
  -e GF_USERS_ALLOW_SIGN_UP=false \
  -e GF_UNIFIED_ALERTING_ENABLED=false \
  -e GF_ANALYTICS_REPORTING_ENABLED=false \
  -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
  -e GF_NEWS_NEWS_FEED_ENABLED=false \
  -e GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/housefull-dashboards/housefull.json \
  -e GF_SECURITY_ADMIN_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -d '\n')" \
  -v "$STATE/grafana/datasources:/etc/grafana/provisioning/datasources:ro" \
  -v "$STATE/grafana/dashboards-provider:/etc/grafana/provisioning/dashboards:ro" \
  -v "$STATE/grafana/dashboards:/etc/grafana/housefull-dashboards:ro" \
  "$GRAFANA_IMAGE"
