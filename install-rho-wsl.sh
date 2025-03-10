#!/usr/bin/env bash
set -euo pipefail
 
###############################################################################
# 1. Parse CLI arguments (simple approach)
###############################################################################
ip=""
customer_name=""
ghcr_key=""
 
while [[ $# -gt 0 ]]; do
  case "$1" in
    -ip|--ip)
      ip="$2"
      shift 2
      ;;
    -customer_name|--customer_name)
      customer_name="$2"
      shift 2
      ;;
    -ghcr_key|--ghcr_key)
      ghcr_key="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done
 
if [[ -z "$ip" || -z "$customer_name" || -z "$ghcr_key" ]]; then
  echo "Usage: $0 --ip <IP> --customer_name <NAME> --ghcr_key <TOKEN>"
  exit 1
fi
 
###############################################################################
# 2. Check required binaries (kubectl, helm, argocd, etc.) installed in WSL
###############################################################################
REQUIRED_BINARIES=(kubectl helm argocd kubens)
 
echo "Checking required binaries..."
for bin in "${REQUIRED_BINARIES[@]}"; do
  if ! command -v "$bin" &>/dev/null; then
    echo "ERROR: '$bin' is not installed or not in PATH. Exiting."
    exit 1
  fi
done
echo "All required binaries present."
 
###############################################################################
# 3. Verify MicroK8s is running
###############################################################################
while true; do
  if microk8s status --wait-ready &>/dev/null; then
    echo "MicroK8s is running. Continuing..."
    break
  else
    echo "MicroK8s not ready. Please start MicroK8s (e.g. 'microk8s start')."
    read -r -p "Press Enter once MicroK8s is running. " _
  fi
done
 
###############################################################################
# 4. Create GHCR login secret if it doesn't exist
###############################################################################
set +e
kubectl -n rho get secret ghcr-login-secret >/dev/null 2>&1
secret_exists=$?
set -e
 
if [[ "$secret_exists" -eq 0 ]]; then
  echo "GHCR login secret 'ghcr-login-secret' already exists in namespace 'rho'."
else
  echo "Creating GHCR login secret."
  kubectl create ns rho || true
  kubectl -n rho create secret docker-registry ghcr-login-secret \
    --docker-server="https://ghcr.io" \
    --docker-username="automation" \
    --docker-password="$ghcr_key" \
    --docker-email="automation@16bit.ai"
fi
 
###############################################################################
# 5. local-path-provisioner (same YAML as your original script)
###############################################################################
cat <<EOF > local-storage.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: local-path-provisioner-service-account
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: local-path-provisioner-role
rules:
  - apiGroups: [""]
    resources: ["nodes", "persistentvolumeclaims", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["endpoints", "persistentvolumes", "pods"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: local-path-provisioner-bind
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: local-path-provisioner-role
subjects:
  - kind: ServiceAccount
    name: local-path-provisioner-service-account
    namespace: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: local-path-provisioner
  namespace: kube-system
spec:
  revisionHistoryLimit: 0
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  selector:
    matchLabels:
      app: local-path-provisioner
  template:
    metadata:
      labels:
        app: local-path-provisioner
    spec:
      priorityClassName: "system-node-critical"
      serviceAccountName: local-path-provisioner-service-account
      tolerations:
        - key: "CriticalAddonsOnly"
          operator: "Exists"
        - key: "node-role.kubernetes.io/control-plane"
          operator: "Exists"
          effect: "NoSchedule"
        - key: "node-role.kubernetes.io/master"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
        - name: local-path-provisioner
          image: rancher/local-path-provisioner:v0.0.24
          imagePullPolicy: IfNotPresent
          command:
            - local-path-provisioner
            - start
            - --config
            - /etc/config/config.json
          volumeMounts:
            - name: config-volume
              mountPath: /etc/config/
          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
      volumes:
        - name: config-volume
          configMap:
            name: local-path-config
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: local-path-config
  namespace: kube-system
data:
  config.json: |-
    {
      "nodePathMap":[
      {
        "node":"DEFAULT_PATH_FOR_NON_LISTED_NODES",
        "paths":["/var/lib/rancher/k3s/storage"]
      }
      ]
    }
  setup: |-
    #!/bin/sh
    while getopts "m:s:p:" opt
    do
        case \$opt in
            p)
            absolutePath=\$OPTARG
            ;;
            s)
            sizeInBytes=\$OPTARG
            ;;
            m)
            volMode=\$OPTARG
            ;;
        esac
    done
    mkdir -m 0777 -p \${absolutePath}
    chmod 700 \${absolutePath}/..
  teardown: |-
    #!/bin/sh
    while getopts "m:s:p:" opt
    do
        case \$opt in
            p)
            absolutePath=\$OPTARG
            ;;
            s)
            sizeInBytes=\$OPTARG
            ;;
            m)
            volMode=\$OPTARG
            ;;
        esac
    done
    rm -rf \${absolutePath}
  helperPod.yaml: |-
    apiVersion: v1
    kind: Pod
    metadata:
      name: helper-pod
    spec:
      containers:
      - name: helper-pod
        image: rancher/mirrored-library-busybox:1.34.1
        imagePullPolicy: IfNotPresent
EOF
 
echo "Applying local storage provisioner..."
kubectl apply -f local-storage.yaml
 
###############################################################################
# 6. Check/Install Metallb (with CRD patching to prevent ownership errors)
###############################################################################
if helm ls --all-namespaces | grep -q metallb; then
  echo "Metallb helm chart is already installed"
else
  echo "Patching any existing MetalLB CRDs to add Helm ownership (if needed)..."
 
  # Typical MetalLB CRDs in 0.13.x
  metalLBcrds=(
    "addresspools.metallb.io"
    "bgppeers.metallb.io"
    "communities.metallb.io"
    "ipaddresspools.metallb.io"
    "l2advertisements.metallb.io"
    "bfdprofiles.metallb.io"
    "bgpadvertisements.metallb.io"
  )
 
  for crd in "${metalLBcrds[@]}"; do
    if kubectl get crd "$crd" >/dev/null 2>&1; then
      echo "Patching CRD '$crd' with Helm ownership metadata..."
      kubectl patch crd "$crd" --type=merge -p "{
        \"metadata\": {
          \"labels\": {
            \"app.kubernetes.io/managed-by\": \"Helm\"
          },
          \"annotations\": {
            \"meta.helm.sh/release-name\": \"metallb\",
            \"meta.helm.sh/release-namespace\": \"metallb\"
          }
        }
      }"
    fi
  done
 
  echo "Installing metallb..."
  helm repo add metallb https://metallb.github.io/metallb
  helm repo update
  helm install metallb metallb/metallb --version 0.13.11 --create-namespace --namespace metallb
  sleep 15
fi
 
cat <<EOF > metallb-config.yaml
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb-ip-address-pool
  namespace: metallb
spec:
  addresses:
  - ${ip}/32
 
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: metallb-l2-config
  namespace: metallb
spec:
  ipAddressPools:
  - metallb-ip-address-pool
EOF
 
echo "Applying metallb configuration..."
kubectl apply -f metallb-config.yaml
 
###############################################################################
# 7. Check/Install Traefik
###############################################################################
if helm ls --all-namespaces | grep -q traefik; then
  echo "Traefik helm chart is already installed"
else
  echo "Installing Traefik..."
  helm repo add traefik https://traefik.github.io/charts
  helm repo update
 
  cat <<EOF > traefik-values.yaml
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
    protocol: TCP
EOF
 
  helm install traefik traefik/traefik --version 24.0.0 -n kube-system -f traefik-values.yaml
  sleep 15
fi
 
###############################################################################
# 8. Check/Install ArgoCD
###############################################################################
if helm ls --all-namespaces | grep -q argocd; then
  echo "ArgoCD is already installed via Helm"
else
  echo "Installing ArgoCD..."
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update
  helm install argocd --namespace argocd --create-namespace --version 5.46.8 argo/argo-cd
  sleep 15
fi
 
###############################################################################
# 9. ArgoCD CLI setup
###############################################################################
echo "Logging in to ArgoCD with --core"
argocd login --core
 
echo "Switching to argocd namespace"
kubens argocd
 
###############################################################################
# 10. Generate SSH key if missing
###############################################################################
if [[ ! -f "./argocd" ]]; then
  echo "Generating SSH key for ArgoCD..."
  ssh-keygen -f argocd -N ""
else
  echo "SSH key './argocd' already exists"
fi
 
echo "Add the following key to GitHub deploy keys for rho-customer-${customer_name}:"
cat ./argocd.pub
read -r -p "Press Enter once done. " _
 
###############################################################################
# 11. Add GitHub repo to ArgoCD
###############################################################################
echo "Checking if ArgoCD already knows about the git repo..."
if argocd repo list -o url | grep -q "git@github.com:16-Bit-Inc/rho-customer-${customer_name}.git"; then
  echo "rho-customer-${customer_name} repo is already in ArgoCD"
else
  echo "Adding the rho-customer-${customer_name} repo to ArgoCD..."
  argocd repo add "git@github.com:16-Bit-Inc/rho-customer-${customer_name}.git" \
    --name "rho-customer-config" \
    --ssh-private-key-path "./argocd"
fi
 
###############################################################################
# 12. Add the 16bit Helm repo to ArgoCD
###############################################################################
if argocd repo list -o url | grep -q "ghcr.io/16-bit-inc/helm"; then
  echo "16Bit Helm repo already exists in ArgoCD"
else
  echo "Adding 16Bit Helm repo to ArgoCD..."
  argocd repo add "ghcr.io/16-bit-inc/helm" --type helm --name 16bit-helm --enable-oci \
    --username "automation" --password "${ghcr_key}"
fi
 
###############################################################################
# 13. Create the ArgoCD Application
###############################################################################
cat <<EOF > argocd-application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${customer_name}
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
    repoURL: git@github.com:16-Bit-Inc/rho-customer-${customer_name}.git
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
 
echo "Applying the ArgoCD Application..."
kubectl apply -f argocd-application.yaml
 
kubens rho || true
 
echo
echo "Rho installation complete! It may take up to 10 minutes for all pods to be ready."
