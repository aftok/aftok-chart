# Aftok Helm Chart

A Helm chart for deploying [Aftok](https://aftok.com), a collaboration platform that enables groups of trusted contributors to work together on commercial projects and fairly distribute revenue based on time contributed.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- PV provisioner support in the underlying infrastructure (for PostgreSQL persistence)

## Installation

### Add the Helm repository (when published)

```bash
helm repo add aftok https://charts.aftok.com
helm repo update
```

### Install from source

```bash
# Clone the repository
git clone https://github.com/aftok/aftok-chart.git
cd aftok-chart

# Build dependencies
helm dependency build ./aftok

# Install with default values (for testing only)
helm install my-aftok ./aftok

# Install with custom values (recommended)
helm install my-aftok ./aftok --values my-values.yaml
```

## Configuration

See [values.yaml](./aftok/values.yaml) for the full list of configurable parameters.

### Key Configuration Sections

| Parameter | Description | Default |
|-----------|-------------|---------|
| `aftokServer.enabled` | Enable the Aftok server | `true` |
| `aftokServer.image.tag` | Server image tag | `latest` |
| `aftokServer.replicaCount` | Number of server replicas | `1` |
| `aftokServer.config.aftokServerCfg` | Server configuration file content | See values.yaml |
| `aftokClient.image.tag` | Client (frontend) image tag | `latest` |
| `aftokSite.image.tag` | Static site image tag | `latest` |
| `nginx.enabled` | Enable nginx reverse proxy | `true` |
| `nginx.service.type` | Service type for nginx | `LoadBalancer` |
| `postgresql.enabled` | Deploy PostgreSQL | `true` |
| `postgresql.auth.password` | PostgreSQL password for aftok user | `""` |
| `ingress.enabled` | Enable ingress | `false` |

### Example Values File

See [examples/values-example.yaml](./examples/values-example.yaml) for a complete example configuration.

## Architecture

The chart deploys the following components:

1. **Aftok Server** - Haskell backend API server
2. **Nginx** - Reverse proxy serving:
   - API requests to the backend (`/api/`)
   - PureScript client application (`/app/`)
   - Static website (`/`)
3. **PostgreSQL** - Database (optional, can use external)

Static assets are served via init containers that copy files from the client and site images into shared volumes that nginx serves.

## Upgrading

```bash
helm upgrade my-aftok ./aftok --values my-values.yaml
```

## Uninstalling

```bash
helm uninstall my-aftok
```

**Note:** This will not delete PersistentVolumeClaims. To fully clean up:

```bash
kubectl delete pvc -l app.kubernetes.io/instance=my-aftok
```

## Development

### Linting

```bash
helm lint ./aftok
```

### Template rendering

```bash
helm template my-aftok ./aftok --values my-values.yaml
```

### Testing

```bash
helm install my-aftok ./aftok --dry-run --debug
```

## Related Repositories

- [aftok/aftok](https://github.com/aftok/aftok) - Backend server
- [aftok/aftok-client](https://github.com/aftok/aftok-client) - PureScript frontend

## License

This chart is licensed under the same terms as the Aftok project.
