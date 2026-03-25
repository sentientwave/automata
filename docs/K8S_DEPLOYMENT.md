# Kubernetes Deployment (Helm)

Automata provides an official Helm chart for deploying the application to a Kubernetes cluster. The chart is optimized for on-premise deployments using `k3s`, but can be adapted for any standard Kubernetes environment.

## Features

The Helm chart (`deploy/k8s`) includes out-of-the-box support for:
- Let's Encrypt automated TLS certificates (via `cert-manager`)
- Remote access over Tailscale (via `tailscale-operator`)
- Custom domains/Ingress using Traefik
- Elixir clustering (Distributed Erlang) via Headless Services
- Application health probes and customizable environment variables

## Prerequisites

To deploy easily on a fresh `k3s` single-node cluster, you should have the following installed on your cluster:

1. **cert-manager** (Required for Let's Encrypt)
2. **tailscale-operator** (Optional, if you wish to expose Automata directly to your Tailnet)
3. **Database** (An accessible PostgreSQL instance)

### Setup Cluster Dependencies

First, install `cert-manager`:
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true
```

Then, create the `letsencrypt-prod` ClusterIssuer that the Automata ingress expects:
```yaml
# cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: traefik
```
Apply it to your cluster: `kubectl apply -f cluster-issuer.yaml`

If you want Tailscale remote access, you do not need to install the operator separately. It can be installed alongside Automata automatically as a Helm dependency. You just need to provide your OAuth credentials during the upgrade step.

## Deploying Automata

Ensure your DNS A records point to your k3s node's public IP. Then deploy the application using the local chart in the `deploy/k8s` directory:

```bash
helm dependency update ./deploy/k8s
helm upgrade --install automata ./deploy/k8s \
  --set env.PHX_HOST=app.yourdomain.com \
  --set ingress.hosts[0].host=app.yourdomain.com \
  --set env.SECRET_KEY_BASE=YOUR_PHOENIX_SECRET \
  --set env.DATABASE_URL=postgres://user:pass@host:5432/db \
  --set tailscale.enabled=true \
  --set tailscale-operator.enabled=true \
  --set tailscale-operator.oauth.clientId="YOUR_OAUTH_CLIENT_ID" \
  --set tailscale-operator.oauth.clientSecret="YOUR_OAUTH_CLIENT_SECRET"
```

### Upgrading the Application Version

The Helm chart isolates the application release version from the chart version. To upgrade to a specific release tag of the `sentientwave/automata` image, pass the tag during upgrade:

```bash
helm upgrade automata ./deploy/k8s --set image.tag=v1.2.3
```
