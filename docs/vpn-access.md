# Private access to Grafana

Grafana has no public address. It's only reachable through a Wag VPN, which is WireGuard with multi-factor authentication.

## How it's protected

| Layer | What it does |
|---|---|
| WireGuard | Only enrolled devices can connect. It's the only port open to the internet. |
| Wag MFA | A connected device still can't reach Grafana until it passes a TOTP code. |
| Private network | Grafana has no published port on the VM. |
| IAP | SSH and device enrolment only work through Google's identity-checked tunnel. |

## Enrol a device

You only do this once per device. Install [WireGuard](https://www.wireguard.com/install/) and an authenticator app first.

**1. Create a one-time enrolment token:**

```bash
gcloud compute ssh housefull-vpn --zone asia-south1-a --tunnel-through-iap --command "sudo docker exec wag wag registration -add -username jeneel"
```

**2. Open a private tunnel to the enrolment page, and leave it running:**

```bash
gcloud compute start-iap-tunnel housefull-vpn 8081 --local-host-port=localhost:8081 --zone asia-south1-a
```

**3. In a second terminal, download your VPN config,** using the token from step 1:

```bash
curl -o housefull.conf "http://localhost:8081/register_device?key=YOUR_TOKEN"
```

**4. Import `housefull.conf` into WireGuard and turn it on.** The file contains your device's private key, so keep it safe and don't commit it.

**5. Open http://10.99.0.1:8080** and scan the QR code with your authenticator app.

## Open Grafana

1. Turn on WireGuard.
2. Sign in at http://10.99.0.1:8080 with your authenticator code.
3. Open http://172.31.9.10:3000

Sessions last up to 8 hours, or 1 hour of inactivity. Five wrong codes lock the account.

## After running Down

Down destroys the VM, including enrolled devices. After the next Up, enrol again.

## Dashboard changes

The VM reads its dashboards at boot, so restart it after changing them:

```bash
gcloud compute instances reset housefull-vpn --zone asia-south1-a
```
