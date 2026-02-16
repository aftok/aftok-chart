{ pkgs, chartPath ? "./aftok" }:

let
  # Common shell snippets used across multiple scripts
  checkChart = ''
    if [ ! -f "${chartPath}/Chart.yaml" ]; then
      echo "Error: Chart not found. Please ensure:"
      echo "  1. You are in the correct directory"
      echo "  2. The chart submodule is initialized: git submodule update --init"
      echo "Current directory: $(pwd)"
      exit 1
    fi
  '';

  setupHelmRepos = ''
    ${pkgs.kubernetes-helm}/bin/helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    ${pkgs.kubernetes-helm}/bin/helm repo update
  '';

  buildChartDeps = ''
    echo "Building Helm chart dependencies..."
    cd ${chartPath}
    ${pkgs.kubernetes-helm}/bin/helm dependency build
    cd - >/dev/null
  '';

  # Script builder: creates a deploy script for a given environment
  mkDeployScript = {
    name,
    releaseName,
    namespace,
    valuesFile,
    preDeployChecks ? "",
    postDeployMessage ? "",
  }:
    pkgs.writeShellScriptBin "deploy-${name}" ''
      set -e
      echo "Deploying Aftok to ${name} environment..."

      ${checkChart}

      ${preDeployChecks}

      # Check if minikube is running (for dev deployments)
      ${pkgs.lib.optionalString (name == "dev") ''
        if ! ${pkgs.minikube}/bin/minikube status | grep -q "Running"; then
          echo "Starting minikube..."
          ${pkgs.minikube}/bin/minikube start --driver=docker --cpus=4 --memory=8192
          ${pkgs.minikube}/bin/minikube addons enable ingress
        fi
      ''}

      ${setupHelmRepos}
      ${buildChartDeps}

      ${pkgs.kubernetes-helm}/bin/helm upgrade --install ${releaseName} ${chartPath} \
        --namespace ${namespace} \
        --create-namespace \
        --values ${valuesFile} \
        --wait

      echo "Deployment to ${name} complete!"
      echo "Checking status..."
      ${pkgs.kubectl}/bin/kubectl get pods -n ${namespace}

      ${postDeployMessage}
    '';

  # Script builder: creates rebuild scripts for docker-based components (client, site)
  mkDockerRebuildScript = { name, defaultPath, imageName, dockerfile ? "." }:
    pkgs.writeShellScriptBin "rebuild-${name}" ''
      set -e
      DIR=''${1:-${defaultPath}}
      NAMESPACE=''${2:-aftok-dev}

      echo "Rebuilding and redeploying ${name} to $NAMESPACE from $DIR..."

      if [ ! -d "$DIR" ]; then
        echo "Directory not found: $DIR"
        echo "Usage: rebuild-${name} [path] [namespace]"
        echo "  path:      Path to ${name} worktree (default: ${defaultPath})"
        echo "  namespace: Kubernetes namespace (default: aftok-dev)"
        exit 1
      fi

      cd "$DIR"

      echo "Building ${name} docker image..."
      eval $(${pkgs.minikube}/bin/minikube docker-env)
      ${pkgs.docker}/bin/docker build -t ${imageName} -f ${dockerfile} .

      echo "Restarting nginx pod to load new ${name} assets..."
      ${pkgs.kubectl}/bin/kubectl delete pod -n "$NAMESPACE" -l app.kubernetes.io/component=nginx --wait=false 2>/dev/null || true

      echo "Waiting for nginx pod to be ready..."
      ${pkgs.kubectl}/bin/kubectl rollout status deployment/"$NAMESPACE"-nginx -n "$NAMESPACE" --timeout=120s

      echo ""
      echo "${name} rebuilt and redeployed!"
      ${pkgs.kubectl}/bin/kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=nginx
    '';

  # Standalone generic scripts
  setup-local-cluster = pkgs.writeShellScriptBin "setup-local-cluster" ''
    set -e
    echo "Setting up local Kubernetes cluster with minikube..."

    # Check if Docker is running
    if ! ${pkgs.docker}/bin/docker info >/dev/null 2>&1; then
      echo "Docker is not running. Please start Docker first."
      exit 1
    fi

    # Start minikube if not running
    if ! ${pkgs.minikube}/bin/minikube status | grep -q "Running"; then
      echo "Starting minikube with optimal settings for Aftok..."
      ${pkgs.minikube}/bin/minikube start \
        --driver=docker \
        --cpus=4 \
        --memory=8192 \
        --kubernetes-version=v1.28.3 \
        --addons=ingress,metrics-server,dashboard
    else
      echo "Minikube is already running"
    fi

    # Enable useful addons
    echo "Enabling useful minikube addons..."
    ${pkgs.minikube}/bin/minikube addons enable ingress
    ${pkgs.minikube}/bin/minikube addons enable metrics-server
    ${pkgs.minikube}/bin/minikube addons enable dashboard

    # Get minikube IP for hosts file configuration
    MINIKUBE_IP=$(${pkgs.minikube}/bin/minikube ip)

    echo "Local cluster setup complete!"
    echo ""
    echo "Cluster info:"
    ${pkgs.kubectl}/bin/kubectl cluster-info
    echo ""

    # Check if aftok.local is already configured
    if grep -q "aftok.local" /etc/hosts 2>/dev/null; then
      CURRENT_IP=$(grep "aftok.local" /etc/hosts | awk '{print $1}' | head -1)
      if [ "$CURRENT_IP" = "$MINIKUBE_IP" ]; then
        echo "/etc/hosts already configured correctly for aftok.local -> $MINIKUBE_IP"
      else
        echo "/etc/hosts has aftok.local pointing to $CURRENT_IP but minikube IP is $MINIKUBE_IP"
        echo "   Run: sudo sed -i 's/^.*aftok.local.*/$MINIKUBE_IP aftok.local/' /etc/hosts"
      fi
    else
      echo "To use http://aftok.local, add this line to /etc/hosts:"
      echo ""
      echo "   $MINIKUBE_IP aftok.local"
      echo ""
      echo "   You can run: echo '$MINIKUBE_IP aftok.local' | sudo tee -a /etc/hosts"
    fi
    echo ""
    echo "You can now run 'deploy-dev' to deploy Aftok"
    echo "After deployment, access the application at: http://aftok.local"
    echo "Run 'minikube dashboard' to open the Kubernetes dashboard"
  '';

  cleanup-dev = pkgs.writeShellScriptBin "cleanup-dev" ''
    set -e
    echo "Cleaning up development environment..."

    # Uninstall helm release
    if ${pkgs.kubernetes-helm}/bin/helm list -n aftok-dev | grep -q aftok-dev; then
      echo "Uninstalling aftok-dev helm release..."
      ${pkgs.kubernetes-helm}/bin/helm uninstall aftok-dev -n aftok-dev
    fi

    # Delete namespace
    if ${pkgs.kubectl}/bin/kubectl get namespace aftok-dev >/dev/null 2>&1; then
      echo "Deleting aftok-dev namespace..."
      ${pkgs.kubectl}/bin/kubectl delete namespace aftok-dev
    fi

    echo "Development environment cleaned up!"
  '';

  rebuild-server = pkgs.writeShellScriptBin "rebuild-server" ''
    set -e
    SERVER_DIR=''${1:-../server/canon}
    NAMESPACE=''${2:-aftok-dev}

    echo "Rebuilding and redeploying server to $NAMESPACE from $SERVER_DIR..."

    # Check directory exists
    if [ ! -d "$SERVER_DIR" ]; then
      echo "Server directory not found: $SERVER_DIR"
      echo "Usage: rebuild-server [server-path] [namespace]"
      echo "  server-path: Path to server worktree (default: ../server/canon)"
      echo "  namespace:   Kubernetes namespace (default: aftok-dev)"
      exit 1
    fi

    # Stage any changes so nix can see them (nix flakes only see staged/committed files)
    echo "Staging changes for nix..."
    cd "$SERVER_DIR"
    git add -A .

    # Build the docker image
    echo "Building server docker image with nix..."
    nix build .#dockerImage -o result

    # Load into minikube's docker
    echo "Loading image into minikube..."
    eval $(${pkgs.minikube}/bin/minikube docker-env)
    ${pkgs.docker}/bin/docker load < result

    # Force delete the pod to pick up the new image
    # (necessary because imagePullPolicy: Never and same tag)
    echo "Restarting server pod..."
    ${pkgs.kubectl}/bin/kubectl delete pod -n "$NAMESPACE" -l app.kubernetes.io/component=server --wait=false 2>/dev/null || true

    # Wait for new pod to be ready
    echo "Waiting for new pod to be ready..."
    ${pkgs.kubectl}/bin/kubectl rollout status deployment/"$NAMESPACE"-server -n "$NAMESPACE" --timeout=120s

    # Show the new pod status
    echo ""
    echo "Server rebuilt and redeployed!"
    ${pkgs.kubectl}/bin/kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=server

    # Show new image ID
    echo ""
    echo "New image ID:"
    ${pkgs.kubectl}/bin/kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=server -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
    echo ""
  '';

  rebuild-client = mkDockerRebuildScript {
    name = "client";
    defaultPath = "../client/ts";
    imageName = "aftok/aftok-client:latest";
    dockerfile = "Dockerfile.k8s";
  };

  rebuild-site = mkDockerRebuildScript {
    name = "site";
    defaultPath = "../aftok.com/work";
    imageName = "aftok/aftok-site:latest";
  };

  rebuild-all = pkgs.writeShellScriptBin "rebuild-all" ''
    set -e
    NAMESPACE=''${1:-aftok-dev}

    echo "Rebuilding and redeploying all components to $NAMESPACE..."
    echo ""

    rebuild-server ../server/canon "$NAMESPACE"
    echo ""
    rebuild-client ../client/work "$NAMESPACE"
    echo ""
    rebuild-site ../aftok.com/work "$NAMESPACE"

    echo ""
    echo "All components rebuilt and redeployed!"
    echo ""
    ${pkgs.kubectl}/bin/kubectl get pods -n "$NAMESPACE"
  '';

  backup-db = pkgs.writeShellScriptBin "backup-db" ''
    set -e

    NAMESPACE=''${1:-aftok-prod}
    BACKUP_DIR="./backups"
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)

    echo "Creating database backup for namespace: $NAMESPACE"

    mkdir -p "$BACKUP_DIR"

    # Get PostgreSQL pod name
    POD_NAME=$(${pkgs.kubectl}/bin/kubectl get pods -l app.kubernetes.io/name=postgresql -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

    if [ -z "$POD_NAME" ]; then
      echo "No PostgreSQL pod found in namespace $NAMESPACE"
      exit 1
    fi

    echo "Backing up from pod: $POD_NAME"

    # Create backup
    ${pkgs.kubectl}/bin/kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
      pg_dump -U aftok aftok > "$BACKUP_DIR/aftok-backup-$NAMESPACE-$TIMESTAMP.sql"

    echo "Backup saved to: $BACKUP_DIR/aftok-backup-$NAMESPACE-$TIMESTAMP.sql"
  '';

  restore-db = pkgs.writeShellScriptBin "restore-db" ''
    set -e

    NAMESPACE=''${1:-aftok-dev}
    BACKUP_FILE="$2"

    if [ -z "$BACKUP_FILE" ]; then
      echo "Usage: restore-db <namespace> <backup-file>"
      echo "Example: restore-db aftok-dev ./backups/aftok-backup-prod-20231201-143000.sql"
      exit 1
    fi

    if [ ! -f "$BACKUP_FILE" ]; then
      echo "Backup file not found: $BACKUP_FILE"
      exit 1
    fi

    echo "Restoring database in namespace: $NAMESPACE from $BACKUP_FILE"

    # Get PostgreSQL pod name
    POD_NAME=$(${pkgs.kubectl}/bin/kubectl get pods -l app.kubernetes.io/name=postgresql -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

    if [ -z "$POD_NAME" ]; then
      echo "No PostgreSQL pod found in namespace $NAMESPACE"
      exit 1
    fi

    echo "Restoring to pod: $POD_NAME"

    # Copy backup to pod and restore
    ${pkgs.kubectl}/bin/kubectl cp "$BACKUP_FILE" "$POD_NAME":/tmp/restore.sql -n "$NAMESPACE"
    ${pkgs.kubectl}/bin/kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
      psql -U aftok -d aftok -f /tmp/restore.sql

    echo "Database restored successfully!"
  '';

  show-logs = pkgs.writeShellScriptBin "show-logs" ''
    NAMESPACE=''${1:-aftok-dev}
    COMPONENT=''${2:-server}

    echo "Showing logs for $COMPONENT in namespace $NAMESPACE"
    echo "Press Ctrl+C to exit"

    ${pkgs.kubectl}/bin/kubectl logs -f -l app.kubernetes.io/component="$COMPONENT" -n "$NAMESPACE"
  '';

  build-chart = pkgs.writeShellScriptBin "build-chart" ''
    set -e
    ${checkChart}
    ${setupHelmRepos}
    ${buildChartDeps}
    echo "Chart dependencies built successfully!"
    echo "Dependencies are now available in ${chartPath}/charts/"
  '';

  build-images = pkgs.writeShellScriptBin "build-images" ''
    set -e
    echo "Building all Aftok Docker images..."

    # Check if we're in the right directory structure
    if [ ! -d "../server/work" ] || [ ! -d "../client/work" ] || [ ! -d "../aftok.com/work" ]; then
      echo "Error: Please run this command from the helm/ directory"
      echo "Expected directory structure: aftok/helm/, aftok/server/work/, aftok/client/work, aftok/aftok.com/work"
      exit 1
    fi

    # Build server image with Nix
    echo "Building Aftok server..."
    cd ../server/work
    nix build
    ${pkgs.docker}/bin/docker load < result
    cd ../../helm

    # Build client image
    echo "Building Aftok client..."
    cd ../client/work
    # Initialize submodules if needed
    git submodule update --init --recursive
    ${pkgs.docker}/bin/docker build -t aftok/aftok-client:latest -f Dockerfile.k8s .
    cd ../../helm

    # Build site image
    echo "Building Aftok site..."
    cd ../aftok.com/work
    ${pkgs.docker}/bin/docker build -t aftok/aftok-site:latest .
    cd ../../helm

    echo "All images built successfully!"
    echo "Available images:"
    ${pkgs.docker}/bin/docker images | grep aftok
  '';

  # Local development deploy command. Uses sensible defaults so no private
  # values file is needed - just run `deploy-dev` from the chart directory.
  deploy-dev = pkgs.writeShellScriptBin "deploy-dev" ''
    set -e
    echo "Deploying Aftok to local development environment..."

    ${checkChart}

    # Start minikube if not running
    if ! ${pkgs.minikube}/bin/minikube status | grep -q "Running"; then
      echo "Starting minikube..."
      ${pkgs.minikube}/bin/minikube start --driver=docker --cpus=4 --memory=8192
      ${pkgs.minikube}/bin/minikube addons enable ingress
    fi

    ${setupHelmRepos}
    ${buildChartDeps}

    # Write a temporary values file with local dev configuration
    VALUES_FILE=$(mktemp /tmp/aftok-dev-values.XXXXXX.yaml)
    trap "rm -f $VALUES_FILE" EXIT

    cat > "$VALUES_FILE" <<'YAML'
    aftokServer:
      image:
        pullPolicy: Never
      config:
        aftokServerCfg: |
          port = 8000
          hostname = "aftok.local"
          secureCookies = false
          corsAllowedOrigins = ["http://aftok.local"]
          db {
            host = "aftok-dev-postgresql"
            port = 5432
            user = "aftok"
            pass = "aftok-dev"
            db = "aftok"
            numStripes = 1
            idleTime = 5
            maxResourcesPerStripe = 20
          }
          templatePath = "/opt/aftok/server/templates/"

    aftokClient:
      image:
        pullPolicy: Never

    aftokSite:
      image:
        pullPolicy: Never

    postgresql:
      auth:
        postgresPassword: "aftok-dev"
        password: "aftok-dev"

    nginx:
      service:
        type: NodePort
        httpPort: 80
        nodePort: 30080

    mailpit:
      enabled: true
    YAML

    ${pkgs.kubernetes-helm}/bin/helm upgrade --install aftok-dev ${chartPath} \
      --namespace aftok-dev \
      --create-namespace \
      --values "$VALUES_FILE" \
      --wait

    echo ""
    echo "Development deployment complete!"
    echo "Checking status..."
    ${pkgs.kubectl}/bin/kubectl get pods -n aftok-dev
    echo ""
    echo "Access the application at: http://aftok.local"
    echo "  (Ensure /etc/hosts is configured - run setup-local-cluster for instructions)"
    echo ""
    echo "Direct NodePort URL: http://$(${pkgs.minikube}/bin/minikube ip):30080"
  '';

  # All generic scripts as a list, for easy inclusion in dev shells
  genericScripts = [
    setup-local-cluster
    cleanup-dev
    deploy-dev
    rebuild-server
    rebuild-client
    rebuild-site
    rebuild-all
    backup-db
    restore-db
    show-logs
    build-chart
    build-images
  ];

  # Package dependencies for k8s development
  k8sToolDeps = with pkgs; [
    # Core Kubernetes tools
    kubernetes-helm
    kubectl
    minikube
    k9s

    # Cloud provider CLIs
    google-cloud-sdk  # For GKE
    awscli2           # For EKS
    azure-cli         # For AKS

    # Container tools
    docker

    # Monitoring and debugging
    kubectx           # Switch between contexts easily (includes kubens)
    stern             # Multi-pod log streaming
    dive              # Docker image analysis

    # General utilities
    curl
    jq                # JSON processing
    yq                # YAML processing
    envsubst          # Environment variable substitution
  ];

  # Default shell hook with tool info, completions, and aliases
  defaultShellHook = ''
    echo "Aftok Kubernetes Development Environment"
    echo "=========================================="
    echo ""
    echo "Available tools:"
    echo "  helm          - Kubernetes package manager"
    echo "  kubectl       - Kubernetes CLI"
    echo "  minikube      - Local Kubernetes cluster"
    echo "  k9s           - Terminal-based Kubernetes UI"
    echo "  docker        - Container runtime"
    echo ""
    echo "Custom commands:"
    echo "  setup-local-cluster  - Set up minikube with addons"
    echo "  deploy-dev          - Deploy to local minikube with dev defaults"
    echo "  build-chart         - Build Helm chart dependencies"
    echo "  build-images        - Build all Docker images (server, client, site)"
    echo "  cleanup-dev         - Clean up development deployment"
    echo "  backup-db           - Backup database"
    echo "  restore-db          - Restore database from backup"
    echo "  show-logs           - Show application logs"
    echo ""
    echo "Development rebuild commands (stages changes, builds, loads, restarts):"
    echo "  rebuild-server [path] [ns]  - Rebuild server (default: ../server/canon, aftok-dev)"
    echo "  rebuild-client [path] [ns]  - Rebuild client (default: ../client/work, aftok-dev)"
    echo "  rebuild-site [path] [ns]    - Rebuild site (default: ../aftok.com/work, aftok-dev)"
    echo "  rebuild-all [ns]            - Rebuild all components (uses default paths)"
    echo ""
    echo "Cloud CLIs (for manual cloud deployments):"
    echo "  gcloud        - Google Cloud (for GKE)"
    echo "  aws           - Amazon Web Services (for EKS)"
    echo "  az            - Microsoft Azure (for AKS)"
    echo ""
    echo "Quick start (local development):"
    echo "  1. Run 'setup-local-cluster' to set up minikube"
    echo "  2. Run 'deploy-dev' to deploy Aftok locally"
    echo "  3. Use 'rebuild-server', 'rebuild-client', 'rebuild-site' to update components"
    echo ""
    echo "The rebuild-* commands handle image building and loading into minikube"
    echo ""
    echo "Documentation: See helm/README.md for detailed instructions"
    echo ""

    # Set up kubectl completions if available
    if command -v kubectl >/dev/null 2>&1; then
      source <(kubectl completion bash 2>/dev/null || true)
    fi
    if command -v helm >/dev/null 2>&1; then
      source <(helm completion bash 2>/dev/null || true)
    fi

    # Set some useful aliases
    alias k='kubectl'
    alias kgp='kubectl get pods'
    alias kgs='kubectl get services'
    alias kgd='kubectl get deployments'
    alias kaf='kubectl apply -f'
    alias kdel='kubectl delete'
    alias klog='kubectl logs -f'
    alias kexec='kubectl exec -it'

    # Helm aliases
    alias h='helm'
    alias hls='helm list'
    alias hist='helm history'

    echo "Tip: Use 'k' instead of 'kubectl' and 'h' instead of 'helm'"
  '';

in
{
  inherit
    # Shell snippet helpers
    checkChart
    setupHelmRepos
    buildChartDeps

    # Script builder functions
    mkDeployScript
    mkDockerRebuildScript

    # Standalone generic scripts
    setup-local-cluster
    cleanup-dev
    deploy-dev
    rebuild-server
    rebuild-client
    rebuild-site
    rebuild-all
    backup-db
    restore-db
    show-logs
    build-chart
    build-images

    # Aggregated list of all generic scripts
    genericScripts

    # Dev shell building blocks
    k8sToolDeps
    defaultShellHook;
}
