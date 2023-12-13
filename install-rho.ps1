param (
    [string]$ip,
    [string]$customer_name,
    [string]$ghcr_key
)

$binaryName = "choco"

# Attempt to get the full path of the binary
$binaryPath = Get-Command $binaryName -ErrorAction SilentlyContinue

if (-not $binaryPath) {
    Write-Host "Binary '$binaryName' not found. Exiting the script." -ForegroundColor Red
    exit 
}

$binaryName = "kubens"

# Attempt to get the full path of the binary
$binaryPath = Get-Command $binaryName -ErrorAction SilentlyContinue

if (-not $binaryPath) {
    Write-Host "Binary '$binaryName' not found. Exiting the script." -ForegroundColor Red
    exit 
}

$binaryName = "kubectl"

# Attempt to get the full path of the binary
$binaryPath = Get-Command $binaryName -ErrorAction SilentlyContinue

if (-not $binaryPath) {
    Write-Host "Binary '$binaryName' not found. Exiting the script." -ForegroundColor Red
    exit 
}

$binaryName = "helm"

# Attempt to get the full path of the binary
$binaryPath = Get-Command $binaryName -ErrorAction SilentlyContinue

if (-not $binaryPath) {
    Write-Host "Binary '$binaryName' not found. Exiting the script." -ForegroundColor Red
    exit 
}

$binaryName = "argocd"

# Attempt to get the full path of the binary
$binaryPath = Get-Command $binaryName -ErrorAction SilentlyContinue

if (-not $binaryPath) {
    Write-Host "Binary '$binaryName' not found. Exiting the script." -ForegroundColor Red
    exit 
}

Write-Host "All the binaries are present. Continuing with the installation." -ForegroundColor Blue

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

Write-Host "Local storage yaml file created at: $TempFilePath" -ForegroundColor Blue

Write-Host "Applying local storage provisioner" -ForegroundColor Blue
kubectl apply -f .\$TempFilePath

Write-Host "Installing metallb service load balancer" -ForegroundColor Blue
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm -n metallb install metallb metallb/metallb --version 0.13.11 --create-namespace

Start-Sleep -Seconds 15

Write-Host "Private IP: $ip" -ForegroundColor Blue

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

Write-Host "Metallb config yaml file created at: $TempFilePath" -ForegroundColor Blue
Write-Host "Applying metallb configuration" -ForegroundColor Blue
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

Write-Host "Traefik values yaml file created at: $TempFilePath" -ForegroundColor Blue

Write-Host "Installing traefik" -ForegroundColor Blue
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm -n kube-system install traefik traefik/traefik --version 24.0.0 -f $TempFilePath

Start-Sleep -Seconds 15

Write-Host "Installing argocd" -ForegroundColor Blue
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd --namespace argocd --create-namespace --version 5.46.8 argo/argo-cd

Start-Sleep -Seconds 15

Write-Host "Setting up argocd CLI" -ForegroundColor Blue
argocd login --core
kubens argocd

Write-Host "Generating SSH Key" -ForegroundColor Blue
ssh-keygen -f argocd -N " "

Write-Host "Add the following key to the list of deploy keys for rho-customer-$customer_name repo in GitHub" -ForegroundColor Blue
Write-Host
Get-Content .\argocd.pub
Write-Host

Read-Host "Press enter once you are done"

Write-Host "Adding customer repo to ArgoCD" -ForegroundColor Blue
argocd repo add "git@github.com:16-Bit-Inc/rho-customer-$customer_name.git" --name rho-customer-config --ssh-private-key-path .\argocd

Write-Host "Adding 16Bit Helm Repo to ArgoCD" -ForegroundColor Blue
argocd repo add "ghcr.io/16-bit-inc/helm" --type helm --name 16bit-helm --enable-oci --username "automation" --password "$ghcr_key"

Write-Host "Creating the ArgoCD application" -ForegroundColor Blue

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
Write-Host "ArgoCD application created at: $TempFilePath" -ForegroundColor Blue

kubectl apply -f .\$TempFilePath

Write-Host "Note: Rho could take up to 10 more minutes to fully install (all the pods to become ready)" -ForegroundColor Blue