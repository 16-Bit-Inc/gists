param (
    [string]$ip,
    [string]$customer_name,
    [string]$ghcr_key
)

if (-not $ip) {
    Write-Host "ip is required. Please provide a value for ip." -ForegroundColor Red
    exit 1
}

if (-not $customer_name) {
    Write-Host "customer_name is required. Please provide a value for customer_name." -ForegroundColor Red
    exit 1
}

if (-not $ghcr_key) {
    Write-Host "ghcr_key is required. Please provide a value for ghcr_key." -ForegroundColor Red
    exit 1
}

$binaryName = "choco"

# Attempt to get the full path of the binary
$binaryPath = Get-Command $binaryName -ErrorAction SilentlyContinue

if (-not $binaryPath) {
    Write-Host "Binary '$binaryName' not found. Exiting the script." -ForegroundColor Red
    exit 1
}

$binaryName = "kubens"

# Attempt to get the full path of the binary
$binaryPath = Get-Command $binaryName -ErrorAction SilentlyContinue

if (-not $binaryPath) {
    Write-Host "Binary '$binaryName' not found. Exiting the script." -ForegroundColor Red
    exit 1
}

$binaryName = "kubectl"

# Attempt to get the full path of the binary
$binaryPath = Get-Command $binaryName -ErrorAction SilentlyContinue

if (-not $binaryPath) {
    Write-Host "Binary '$binaryName' not found. Exiting the script." -ForegroundColor Red
    exit 1
}

$binaryName = "helm"

# Attempt to get the full path of the binary
$binaryPath = Get-Command $binaryName -ErrorAction SilentlyContinue

if (-not $binaryPath) {
    Write-Host "Binary '$binaryName' not found. Exiting the script." -ForegroundColor Red
    exit 1
}

$binaryName = "argocd"

# Attempt to get the full path of the binary
$binaryPath = Get-Command $binaryName -ErrorAction SilentlyContinue

if (-not $binaryPath) {
    Write-Host "Binary '$binaryName' not found. Exiting the script." -ForegroundColor Red
    exit 1
}

Write-Host "All the binaries are present. Continuing with the installation." -ForegroundColor Cyan

while ($true) {
    kubectl get nodes

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Docker Desktop is running. Proceeding the installation script." -ForegroundColor Cyan
        break
    } else {
        Write-Host "Docker Desktop is not running. Please start Docker Desktop." -ForegroundColor Red
        Write-Host 
        Read-Host "Press Enter once docker desktop is running."
    }
}

kubectl -n rho get secret "ghcr-login-secret"

if ($LASTEXITCODE -eq 0) {
    Write-Host "GHCR Login Secret already exists" -ForegroundColor Cyan
    break
} else {
    Write-Host "Creating GHCR Login Secret" -ForegroundColor Red
    kubectl create ns rho
    kubectl -n rho create secret docker-registry ghcr-login-secret `
    --docker-server=https://ghcr.io `
    --docker-username=automation `
    --docker-password=$ghcr_key `
    --docker-email=automation@16bit.ai
}

$Content = @'
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
        case $opt in
            p)
            absolutePath=$OPTARG
            ;;
            s)
            sizeInBytes=$OPTARG
            ;;
            m)
            volMode=$OPTARG
            ;;
        esac
    done
    mkdir -m 0777 -p ${absolutePath}
    chmod 700 ${absolutePath}/..
  teardown: |-
    #!/bin/sh
    while getopts "m:s:p:" opt
    do
        case $opt in
            p)
            absolutePath=$OPTARG
            ;;
            s)
            sizeInBytes=$OPTARG
            ;;
            m)
            volMode=$OPTARG
            ;;
        esac
    done
    rm -rf ${absolutePath}
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
'@

$TempFilePath = "local-storage.yaml"
Set-Content -Path $TempFilePath -Value $Content

Write-Host "Local storage yaml file created at: $TempFilePath" -ForegroundColor Cyan

Write-Host "Applying local storage provisioner" -ForegroundColor Cyan
kubectl apply -f .\$TempFilePath

# Check if the Helm chart is installed
$helmChartExists = helm ls --short --all-namespaces | Select-String "metallb"

if ($helmChartExists) {
    Write-Host "Metallb helm chart is already installed" -ForegroundColor Cyan
} else {
    Write-Host "Installing metallb service load balancer" -ForegroundColor Cyan
    helm repo add metallb https://metallb.github.io/metallb
    helm repo update
    helm -n metallb install metallb metallb/metallb --version 0.13.11 --create-namespace
    Start-Sleep -Seconds 15
}

Write-Host "Private IP: $ip" -ForegroundColor Cyan

$Content = @"
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb-ip-address-pool
  namespace: metallb
spec:
  addresses:
  - $ip/32

---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: metallb-l2-config
  namespace: metallb
spec:
  ipAddressPools:
  - metallb-ip-address-pool
"@

$TempFilePath = "metallb-config.yaml"
Set-Content -Path $TempFilePath -Value $Content

Write-Host "Metallb config yaml file created at: $TempFilePath" -ForegroundColor Cyan
Write-Host "Applying metallb configuration" -ForegroundColor Cyan
kubectl apply -f .\$TempFilePath

$TempFilePath = "traefik-values.yaml"

$Content = @"
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
"@

Set-Content -Path $TempFilePath -Value $Content

Write-Host "Traefik values yaml file created at: $TempFilePath" -ForegroundColor Cyan

$helmChartExists = helm ls --short --all-namespaces | Select-String "traefik"

if ($helmChartExists) {
    Write-Host "Traefik helm chart is already installed" -ForegroundColor Cyan
} else {
    Write-Host "Installing traefik" -ForegroundColor Cyan
    helm repo add traefik https://traefik.github.io/charts
    helm repo update
    helm -n kube-system install traefik traefik/traefik --version 24.0.0 -f $TempFilePath
    Start-Sleep -Seconds 15
}

$helmChartExists = helm ls --short --all-namespaces | Select-String "argocd"

if ($helmChartExists) {
    Write-Host "ArgoCD helm chart is already installed" -ForegroundColor Cyan
} else {
    Write-Host "Installing argocd" -ForegroundColor Cyan
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    helm install argocd --namespace argocd --create-namespace --version 5.46.8 argo/argo-cd
    Start-Sleep -Seconds 15
}

Write-Host "Setting up argocd CLI" -ForegroundColor Cyan
argocd login --core
kubens argocd

$sshKeyPath = ".\argocd"

if (Test-Path -Path $sshKeyPath -PathType Leaf) {
    Write-Host "ArgoCD SSH key already exists" -BackgroundColor Cyan
} else {
    Write-Host "Generating SSH Key" -ForegroundColor Cyan
    ssh-keygen -f argocd -N " "
}


Write-Host "Add the following key to the list of deploy keys for rho-customer-$customer_name repo in GitHub" -ForegroundColor Cyan
Write-Host
Get-Content .\argocd.pub
Write-Host

Read-Host "Press enter once you are done"

# Check if the rho-customer-config repo exists in ArgoCD
if ((argocd repo list -o url) -match "git@github.com:16-Bit-Inc/rho-customer-$customer_name.git") {
    Write-Host "rho-customer-config repo already exists in ArgoCD" -ForegroundColor Cyan
} else {
    Write-Host "Adding rho-customer-config repo to ArgoCD" -ForegroundColor Cyan
    argocd repo add "git@github.com:16-Bit-Inc/rho-customer-$customer_name.git" --name rho-customer-config --ssh-private-key-path .\argocd
}

# Check if the 16Bit Helm repo exists in ArgoCD
if ((argocd repo list -o url) -match "ghcr.io/16-bit-inc/helm") {
    Write-Host "16Bit Helm repo already exists in ArgoCD" -ForegroundColor Cyan
} else {
    Write-Host "Adding 16Bit Helm repo to ArgoCD" -ForegroundColor Cyan
    argocd repo add "ghcr.io/16-bit-inc/helm" --type helm --name 16bit-helm --enable-oci --username "automation" --password "$ghcr_key"
}

Write-Host "Creating the ArgoCD application" -ForegroundColor Cyan

$Content = @"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $customer_name
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
    repoURL: git@github.com:16-Bit-Inc/rho-customer-$customer_name.git
    targetRevision: HEAD
  sources: []
  project: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
"@

$TempFilePath = "argocd-application.yaml"
Set-Content -Path $TempFilePath -Value $Content
Write-Host "ArgoCD application created at: $TempFilePath" -ForegroundColor Cyan

kubectl apply -f .\$TempFilePath

Write-Host "Rho installation complete!" -ForegroundColor Green
Write-Host
Write-Host "Note: Rho could take up to 10 more minutes to fully install (all the pods to become ready)." -ForegroundColor Yellow
