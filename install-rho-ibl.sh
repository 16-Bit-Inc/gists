#!/bin/bash
set -e

log_path="/tmp/rho-install.log"

exec 3>&1
exec >>"$log_path" 2>&1

echo_to_console() {
    echo "$@" | tee -a "$log_path" >&3
}

# Function to check if a binary is installed
check_binary() {
  if ! which $1 > /dev/null; then
    echo_to_console "$1 is not installed. Install $1 to proceed."
    exit 1
  fi
}

# Minimum required RAM in GB
min_ram=7
if [ -n "$MIN_RAM" ]; then
    echo_to_console ">>>> Using $MIN_RAM as the minimum RAM requirement."
    min_ram="$MIN_RAM"
fi

# Check RAM
total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
total_ram_gb=$((total_ram_kb / 1024 / 1024))

if [ "$total_ram_gb" -lt "$min_ram" ]; then
    echo_to_console ">>>> Insufficient RAM (required: ${min_ram} GB, available: ${total_ram_gb} GB)"
    exit 1
fi

data_dir="/var/lib/rancher/k3s"
mountpoint="/"
if [ -n "$DATA_DIR" ]; then

    if [ ! -d "$DATA_DIR" ]; then
        echo_to_console "DATA_DIR ${DATA_DIR} does not exist. Please provide an existing directory."
        exit 1
    fi

    echo_to_console ">>>> Using $DATA_DIR as the data directory for K3s"
    data_dir="$DATA_DIR"
    mountpoint=$(df --output=target $data_dir | tail -n 1 | awk '{print $1}')
    echo_to_console ">>>> Using ${mountpoint} as the mount point for data directory ${data_dir}"
fi

# Minimum required free disk space in GB
min_disk=80
if [ -n "$MIN_DISK" ]; then
    echo_to_console ">>>> Using $MIN_DISK as the minimum free disk space requirement."
    min_disk="$MIN_DISK"
fi

# Check free disk space
free_disk_space_kb=$(df $mountpoint | grep $mountpoint | awk '{print $4}')
free_disk_space_gb=$((free_disk_space_kb / 1024 / 1024))

if [ "$free_disk_space_gb" -lt "$min_disk" ]; then
    echo_to_console ">>>> Insufficient disk space in ${mountpoint} (required: ${min_disk} GB, available: ${free_disk_space_gb} GB)"
    exit 1
fi

echo_to_console ">>>> System meets the minimum requirements."

check_binary git
echo_to_console ">>>> Required binaries are present."

echo_to_console ">>>> Starting Rho installation"
echo_to_console ">>>> Logging Rho installation at $log_path"

if [ -z "$RHO_CUSTOMER_NAME" ]; then
    echo_to_console ">>>> Environment variable RHO_CUSTOMER_NAME not set, exiting installation"
    exit 1
fi

if [ -z "$RHO_GHCR_KEY" ]; then
    echo_to_console ">>>> Environment variable RHO_GHCR_KEY not set, exiting installation"
    exit 1
fi

# ---------------------------------------------------------------------------
# VPN-site configuration
# ---------------------------------------------------------------------------
# Some customer sites (e.g. Keep VPN) inject a wildcard search domain into the
# host's /etc/resolv.conf. With the default ndots:5 setting, in-cluster Go
# resolvers (ArgoCD, etc.) try the search-domain expansion FIRST for any name
# with fewer than 5 dots, so "github.com" resolves to
# "github.com.<vpn-search-domain>" — which exists and points at an internal IP
# — and ArgoCD's repo-add silently times out.
#
# Set RHO_VPN_SITE=true to apply two fixes:
#   1. Configure CoreDNS to forward upstream to public resolvers directly
#      (pre-staged via /var/lib/rancher/k3s/server/manifests so it survives
#      restarts and the K3s Helm controller).
#   2. Patch the ArgoCD pods with dnsConfig options ndots:1 so literal names
#      are tried before search-domain expansion.
#
# RHO_DNS_SERVERS overrides the upstream resolvers (default: 1.1.1.1 8.8.8.8).
# ---------------------------------------------------------------------------
rho_vpn_site="${RHO_VPN_SITE:-false}"
rho_dns_servers="${RHO_DNS_SERVERS:-1.1.1.1 8.8.8.8}"

if [ "$rho_vpn_site" = "true" ]; then
    echo_to_console ">>>> RHO_VPN_SITE=true — VPN-site DNS workarounds will be applied"
    echo_to_console ">>>> Using upstream DNS resolvers: $rho_dns_servers"
fi

if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    echo_to_console ">>>> k3s is already installed"
else
  echo_to_console ">>>> Installing k3s"

  # If this is a VPN site, pre-stage a CoreDNS HelmChartConfig BEFORE k3s
  # starts so CoreDNS comes up with the correct upstream resolvers from the
  # very first boot. This avoids a chicken-and-egg problem where CoreDNS
  # would otherwise inherit the host's VPN-tainted resolv.conf.
  if [ "$rho_vpn_site" = "true" ]; then
    echo_to_console ">>>> Pre-staging CoreDNS HelmChartConfig for VPN site"
    sudo mkdir -p $data_dir/server/manifests
    sudo sh -c "cat > $data_dir/server/manifests/coredns-config.yaml" <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-coredns
  namespace: kube-system
spec:
  valuesContent: |-
    servers:
      - zones:
          - zone: .
        port: 53
        plugins:
          - name: errors
          - name: health
          - name: ready
          - name: kubernetes
            parameters: cluster.local in-addr.arpa ip6.arpa
            configBlock: |-
              pods insecure
              fallthrough in-addr.arpa ip6.arpa
          - name: hosts
            parameters: /etc/coredns/NodeHosts
            configBlock: |-
              ttl 60
              reload 15s
              fallthrough
          - name: prometheus
            parameters: :9153
          - name: forward
            parameters: . $rho_dns_servers
          - name: cache
            parameters: 30
          - name: loop
          - name: reload
          - name: loadbalance
EOF
  fi

  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.27.3+k3s1 sh -s - \
    --write-kubeconfig ~/.kube/config \
    --write-kubeconfig-mode 600 \
    --kubelet-arg=image-gc-high-threshold=50 \
    --kubelet-arg=image-gc-low-threshold=30 \
    --data-dir $data_dir
  sudo chown -R $USER:$USER ~/.kube
  echo 'alias k=kubectl' >> ~/.bashrc
  source ~/.bashrc
  sleep 5
  sudo sh -c "echo 'apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    providers:
      kubernetesCRD:
        allowCrossNamespace: true
    ports:
      dicom:
        port: 4242
        expose: true
        exposedPort: 4242
        protocol: TCP
      db:
        port: 5432
        expose: true
        exposedPort: 5432
        protocol: TCP' > $data_dir/server/manifests/traefik-config.yaml"
fi

# For VPN sites, also patch the running CoreDNS configmap directly in case
# the HelmChartConfig pre-stage didn't take effect (e.g. on re-runs against
# an existing k3s install) and bounce CoreDNS to pick it up.
if [ "$rho_vpn_site" = "true" ]; then
    echo_to_console ">>>> Patching CoreDNS configmap to forward to $rho_dns_servers"
    kubectl -n kube-system patch configmap coredns --type merge -p "
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        hosts /etc/coredns/NodeHosts {
          ttl 60
          reload 15s
          fallthrough
        }
        prometheus :9153
        forward . $rho_dns_servers
        cache 30
        loop
        reload
        loadbalance
    }
" || true
    kubectl -n kube-system rollout restart deploy/coredns || true
    kubectl -n kube-system rollout status deploy/coredns --timeout=120s || true
fi

if kubectl -n rho get secret "ghcr-login-secret"; then
  echo_to_console ">>>> GHCR Login Secret already exists"
else
  echo_to_console ">>>> Creating GHCR Login Secret"
  kubectl create ns rho
  kubectl -n rho create secret docker-registry ghcr-login-secret \
  --docker-server=https://ghcr.io \
  --docker-username=automation \
  --docker-password=$RHO_GHCR_KEY \
  --docker-email=automation@16bit.ai
fi

if which brew; then
    echo_to_console ">>>> Homebrew is already installed"
else
  echo_to_console ">>>> Installing homebrew"
  echo | /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  (echo; echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"') >> ~/.bashrc
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

set +e

if which kubens; then
  echo_to_console ">>>> kubectx is already installed"
else
  echo_to_console ">>>> Installing kubectx"
  brew install kubectx
fi

if which argocd; then
  echo_to_console ">>>> ArgoCD cli is already installed"
else
  echo_to_console ">>>> Installing ArgoCD cli"
  brew install argocd
fi

if which helm; then
  echo_to_console ">>>> helm is already installed"
else
  echo_to_console ">>>> Installing helm"
  brew install helm
fi

if which jq; then
  echo_to_console ">>>> jq is already installed"
else
  echo_to_console ">>>> Installing jq"
  brew install jq
fi

set -e

if helm ls --short | grep -q "argocd"; then
  echo_to_console ">>>> ArgoCD agent is already installed"
else
  echo_to_console ">>>> Installing ArgoCD agent"
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update
  helm install argocd --namespace argocd --create-namespace --version 5.46.8 argo/argo-cd \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --set controller.metrics.enabled=true \
  --set controller.metrics.service.annotations."k8s\.grafana\.com/scrape"=true \
  --set controller.metrics.service.annotations."k8s\.grafana\.com/metrics\.portNumber"=8082
fi

# For VPN sites, patch ArgoCD pods with ndots:1 so Go's resolver tries
# literal names before search-domain expansion. Without this, "github.com"
# resolves to "github.com.<vpn-search-domain>" and repo-add hangs.
if [ "$rho_vpn_site" = "true" ]; then
    echo_to_console ">>>> Patching ArgoCD pods with ndots:1 for VPN site"
    for r in deploy/argocd-repo-server deploy/argocd-server statefulset/argocd-application-controller; do
        kubectl -n argocd patch $r --type merge -p '
spec:
  template:
    spec:
      dnsConfig:
        options:
          - name: ndots
            value: "1"
' || true
    done

    echo_to_console ">>>> Waiting for ArgoCD pods to roll with new dnsConfig"
    # Single-node clusters can't fit 2x argocd pods during a rolling update,
    # so force the old replicas down to free resources for the new ones.
    kubectl -n argocd rollout restart deploy/argocd-repo-server deploy/argocd-server statefulset/argocd-application-controller || true
    sleep 5
    kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-repo-server --field-selector=status.phase=Running --grace-period=10 2>/dev/null || true
    kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-server --field-selector=status.phase=Running --grace-period=10 2>/dev/null || true
    kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s || true
    kubectl -n argocd rollout status deploy/argocd-server --timeout=300s || true
    kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s || true

    # Sanity-check DNS from inside the repo-server before proceeding.
    echo_to_console ">>>> Verifying DNS resolution from argocd-repo-server"
    resolved=$(kubectl -n argocd exec deploy/argocd-repo-server -- sh -c "getent hosts github.com" 2>/dev/null | awk '{print $1}' | head -n1)
    if [ -z "$resolved" ]; then
        echo_to_console ">>>> WARNING: Could not resolve github.com from argocd-repo-server. Repo add may fail."
    else
        echo_to_console ">>>> github.com resolves to $resolved from argocd-repo-server"
    fi
fi

echo_to_console ">>>> Setting up ArgoCD CLI"
argocd login --core
kubens argocd

if [ -f ~/.ssh/argocd ]; then
  echo_to_console ">>>> ArgoCD SSH key already exists"
else
  echo_to_console ">>>> Generating ArgoCD SSH key"
  ssh-keygen -f ~/.ssh/argocd -N ""
fi

echo_to_console
echo_to_console ">>>> Add the following public SSH key to rho-customer-$RHO_CUSTOMER_NAME GitHub repo's deploy keys:"
echo_to_console
echo_to_console $(cat ~/.ssh/argocd.pub)
echo_to_console
echo_to_console ">>>> Once done, press enter to continue"
read

sleep 8

while true; do
deployments_not_ready=$(kubectl -n argocd get deploy -o custom-columns='DEPLOY:metadata.name,READY:status.readyReplicas' | grep '<none>' | wc -l)
if [ $deployments_not_ready -ne 0 ];then
    echo_to_console ">>>> ArgoCD deployments are not ready waiting..."
    sleep 10
else
    sleep 2
    echo_to_console ">>>> ArgoCD deployments ready, proceeding with configuring the rho-customer-config and helm repo"
    echo_to_console
    break
fi
done

if argocd repo list -o url | grep -q "git@github.com:16-Bit-Inc/rho-customer-$RHO_CUSTOMER_NAME.git"; then
  echo_to_console ">>>> rho-customer-config repo already exists in ArgoCD"
else
  echo_to_console ">>>> Adding rho-customer-config repo to ArgoCD"
  argocd repo add git@github.com:16-Bit-Inc/rho-customer-$RHO_CUSTOMER_NAME.git --name rho-customer-config --ssh-private-key-path ~/.ssh/argocd
fi

if argocd repo list -o url | grep -q "ghcr.io/16-bit-inc/helm"; then
  echo_to_console ">>>> 16Bit Helm repo already exists in ArgoCD"
else
  echo_to_console ">>>> Adding 16Bit Helm repo to ArgoCD"
  argocd repo add "ghcr.io/16-bit-inc/helm" --type helm --name 16bit-helm --enable-oci --username "automation" --password $RHO_GHCR_KEY
fi

if argocd app list -o name | grep -q "argocd/$RHO_CUSTOMER_NAME"; then
  echo_to_console ">>>> ArgoCD application already exists"
else
echo_to_console ">>>> Creating ArgoCD application"
cat > /tmp/rho.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $RHO_CUSTOMER_NAME
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    name: ''
    namespace: argocd
    server: 'https://kubernetes.default.svc'
  source:
    path: ./
    repoURL: git@github.com:16-Bit-Inc/rho-customer-$RHO_CUSTOMER_NAME.git
    targetRevision: HEAD
  sources: []
  project: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
  kubectl apply -f /tmp/rho.yaml
fi

echo_to_console ">>>> Checking device type..."
sleep 30

device=$(argocd app get argocd/rho -o json | jq -r .spec.source.helm.valuesObject.device)
if [ "$device" = "gpu" ]; then
    echo_to_console ">>>> Device is set to GPU"
    echo_to_console ">>>> Installing Nvidia Operator..."

    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
    helm repo update

    helm install --wait nvidiagpu \
    -n gpu-operator --create-namespace \
    --set toolkit.env[0].name=CONTAINERD_CONFIG \
    --set toolkit.env[0].value=$data_dir/agent/etc/containerd/config.toml \
    --set toolkit.env[1].name=CONTAINERD_SOCKET \
    --set toolkit.env[1].value=/run/k3s/containerd/containerd.sock \
    --set toolkit.env[2].name=CONTAINERD_RUNTIME_CLASS \
    --set toolkit.env[2].value=nvidia \
    --set toolkit.env[3].name=CONTAINERD_SET_AS_DEFAULT \
    --set-string toolkit.env[3].value=true \
    nvidia/gpu-operator

    echo_to_console ">>>> Trition Server pod might crash a few times for the first ~10 minutes until the GPU is detected by the Nvidia Operator."
fi

kubens rho

echo_to_console
echo_to_console ">>>> Rho installation complete!"
echo_to_console
echo_to_console ">>>> Note: Please source the bashrc file: source ~/.bashrc"
echo_to_console ">>>> Note: Rho could take up to 10 more minutes to fully install (all the pods to become ready)."
