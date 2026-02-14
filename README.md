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

### Nix Development Environment

This repository includes a Nix flake that provides a development shell with
Kubernetes tooling and generic deployment scripts. These are the scripts that
don't require access to private configuration (environment-specific values
files, credentials, etc.).

```bash
# Enter the development shell (provides kubectl, helm, minikube, etc.)
nix develop

# Available generic scripts:
setup-local-cluster    # Set up minikube with addons
cleanup-dev            # Clean up development deployment
rebuild-server [path] [namespace]    # Rebuild and redeploy server
rebuild-client [path] [namespace]    # Rebuild and redeploy client
rebuild-client-ts [path] [namespace] # Rebuild and redeploy TS client
rebuild-site [path] [namespace]      # Rebuild and redeploy site
rebuild-all [namespace]              # Rebuild all components
backup-db [namespace]                # Backup database
restore-db <namespace> <file>        # Restore database from backup
show-logs [namespace] [component]    # Show application logs
build-chart                          # Build Helm chart dependencies
build-images                         # Build all Docker images
```

Environment-specific deploy commands (`deploy-dev`, `deploy-staging`,
`deploy-prod`) are **not** provided here. Those live in the private deployment
repository, which references private values files containing credentials and
environment configuration. See the private repo's README for details.

### Deployment Library (`lib.nix`)

The `lib.nix` file at the root of this repository is a Nix library that
packages all the generic deployment tooling. It is designed to be imported by
both this flake and by downstream private deployment repositories.

`lib.nix` exports:

| Export | Description |
|--------|-------------|
| `mkDeployScript { name, releaseName, namespace, valuesFile, ... }` | Builder function: creates a deploy script for a given environment |
| `mkDockerRebuildScript { name, defaultPath, imageName, ... }` | Builder function: creates rebuild scripts for docker-based components |
| `genericScripts` | List of all standalone script derivations (for `buildInputs`) |
| `k8sToolDeps` | List of k8s/cloud/utility package dependencies |
| `defaultShellHook` | Shell hook with tool info, completions, and aliases |
| `checkChart`, `setupHelmRepos`, `buildChartDeps` | Shell snippet strings for use in custom scripts |
| Individual scripts | `setup-local-cluster`, `rebuild-server`, `backup-db`, etc. |

**Using `lib.nix` from a private deployment repo:**

```nix
# In your private flake.nix:
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    aftok-chart = {
      url = "github:aftok/aftok-chart";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { self, nixpkgs, flake-utils, aftok-chart }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        chartLib = import "${aftok-chart}/lib.nix" {
          inherit pkgs;
          chartPath = "./chart/aftok";  # path to chart relative to working dir
        };

        deploy-dev = chartLib.mkDeployScript {
          name = "dev";
          releaseName = "aftok-dev";
          namespace = "aftok-dev";
          valuesFile = "environments/values-development.yaml";
        };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = chartLib.k8sToolDeps ++ chartLib.genericScripts ++ [ deploy-dev ];
          shellHook = chartLib.defaultShellHook;
        };
      });
}
```

The `chartPath` parameter controls where the Helm chart is located relative to
the working directory at script runtime. When used from within this repo, it
defaults to `"./aftok"`. When used from a private repo where this chart is a
submodule at `chart/`, set it to `"./chart/aftok"`.

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
