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

# Minimum required RAM in MB
MIN_RAM_MB=7500
# Minimum required free disk space in GB
MIN_DISK_GB=80

# Calculate minimum required free disk space in 1K blocks, since `df` outputs in 1K blocks
MIN_DISK_BLOCKS=$((MIN_DISK_GB * 1024 * 1024))

# Check RAM
total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
total_ram_mb=$((total_ram_kb / 1024))

if [ "$total_ram_mb" -lt "$MIN_RAM_MB" ]; then
    echo_to_console ">>>> Insufficient RAM. Required: ${MIN_RAM_MB} MB, Available: ${total_ram_mb} MB."
    exit 1
fi

# Check disk space
free_disk_space_kb=$(df / | grep / | awk '{print $4}')
free_disk_space_gb=$((free_disk_space_kb / 1024 / 1024))

if [ "$free_disk_space_gb" -lt "$MIN_DISK_GB" ]; then
    echo_to_console ">>>> Insufficient disk space. Required: ${MIN_DISK_GB} GB, Available: ${free_disk_space_gb} GB."
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

if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    echo_to_console ">>>> k3s is already installed" 
else
  echo_to_console ">>>> Installing k3s" 
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.27.3+k3s1 sh -s - \
    --write-kubeconfig ~/.kube/config \
    --write-kubeconfig-mode 600 \
    --kubelet-arg=image-gc-high-threshold=50 \
    --kubelet-arg=image-gc-low-threshold=30
  sudo chown -R $USER:$USER ~/.kube
  echo 'alias k=kubectl' >> ~/.bashrc
  source ~/.bashrc
  sleep 5
  sudo sh -c 'echo "apiVersion: helm.cattle.io/v1
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
        protocol: TCP" > /var/lib/rancher/k3s/server/manifests/traefik-config.yaml'
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

sleep 5
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
    --set toolkit.env[0].value=/var/lib/rancher/k3s/agent/etc/containerd/config.toml \
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
