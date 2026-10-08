locals {
  user_data = <<-EOF
#!/bin/bash
set -euo pipefail
 
EXISTING_S3_BUCKET="kops-project"
AWS_REGION="eu-west-3"
CLUSTER_DOMAIN_NAME="gaurav-devops.site"
HOSTED_ZONE_ID="${data.aws_route53_zone.main.zone_id}"
MGMT_USER="ubuntu"
ISTIO_VERSION="1.24.2"
TARGET_DIRECTORY="/home/$MGMT_USER/istio-$ISTIO_VERSION"
PROFILE="default"
KUBERNETES_PATH="/home/$MGMT_USER/.kube/config"
LBC_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-cloudwithliz-space"
GITHUB_CREDENTIALS_SECRET_ARN="${aws_secretsmanager_secret.github_credentials.arn}"
ARGOCD_DOMAIN="argocd.site"

 
echo "--- Starting Bootstrap: $(date) ---"
 
SERVICE_HOSTS=(dashboard argocd stage prod prometheus grafana kiali jaeger zipkin)
 
apt-get update -y
apt-get install -y unzip curl git jq apt-transport-https
 
if ! command -v aws >/dev/null 2>&1; then
  curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip -q awscliv2.zip
  ./aws/install
  rm -rf awscliv2.zip aws/
fi
 
K8S_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/$K8S_VERSION/bin/linux/amd64/kubectl"
chmod +x kubectl
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl
 
KOPS_VERSION=$(curl -s https://api.github.com/repos/kubernetes/kops/releases/latest | jq -r .tag_name)
curl -Lo kops "https://github.com/kubernetes/kops/releases/download/$KOPS_VERSION/kops-linux-amd64"
chmod +x kops
mv kops /usr/local/bin/kops
 
cat >/etc/profile.d/kops_env.sh <<EOT
export KOPS_STATE_STORE="s3://$EXISTING_S3_BUCKET"
export NAME="$CLUSTER_DOMAIN_NAME"
export AWS_REGION="$AWS_REGION"
EOT
chmod +x /etc/profile.d/kops_env.sh
echo "source /etc/profile.d/kops_env.sh" >> /home/$MGMT_USER/.bashrc
 
mkdir -p /home/$MGMT_USER/.ssh
chown -R $MGMT_USER:$MGMT_USER /home/$MGMT_USER/.ssh
chmod 700 /home/$MGMT_USER/.ssh
 
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh
rm -f get_helm.sh
 
echo "Installing ArgoCD CLI..."
VERSION=$(curl -L -s https://raw.githubusercontent.com/argoproj/argo-cd/stable/VERSION)
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/download/v$VERSION/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64
 
sudo su -c "ssh-keygen -t rsa -m pem -q -f /home/$MGMT_USER/.ssh/id_rsa -N ''" $MGMT_USER
 
sudo su -c "kops create cluster \
  --name="$CLUSTER_DOMAIN_NAME" \
  --cloud=aws \
  --zones='$AWS_REGION'a,'$AWS_REGION'b,'$AWS_REGION'c \
  --node-count=5 \
  --node-size=t3.medium \
  --control-plane-size=t3.medium \
  --control-plane-zones='$AWS_REGION'a,'$AWS_REGION'b,'$AWS_REGION'c \
  --topology=private \
  --bastion=true \
  --networking=calico \
  --ssh-public-key=/home/$MGMT_USER/.ssh/id_rsa.pub \
  --state="s3://$EXISTING_S3_BUCKET" \
  --yes" $MGMT_USER
 
sudo su -c "kops update cluster \
  --name=\"$CLUSTER_DOMAIN_NAME\" \
  --state=\"s3://$EXISTING_S3_BUCKET\" \
  --yes" $MGMT_USER
 
sudo su -c "kops export kubecfg \
  --name=\"$CLUSTER_DOMAIN_NAME\" \
  --state=\"s3://$EXISTING_S3_BUCKET\" \
  --admin" $MGMT_USER
 
sudo su -c "kops validate cluster \
  --name=\"$CLUSTER_DOMAIN_NAME\" \
  --state=\"s3://$EXISTING_S3_BUCKET\" \
  --wait 20m" $MGMT_USER
 
sudo su -c "kops edit cluster \
  --name=\"$CLUSTER_DOMAIN_NAME\" \
  --state=\"s3://$EXISTING_S3_BUCKET\" \
  --set spec.certManager.enabled=true" $MGMT_USER
 
sudo su -c "kops edit cluster \
  --name=\"$CLUSTER_DOMAIN_NAME\" \
  --state=\"s3://$EXISTING_S3_BUCKET\" \
  --set spec.cloudProvider.aws.loadBalancerController.enabled=true" $MGMT_USER
 
sudo su -c "kops update cluster \
  --name=\"$CLUSTER_DOMAIN_NAME\" \
  --state=\"s3://$EXISTING_S3_BUCKET\" \
  --yes" $MGMT_USER
 
sudo su -c "kops rolling-update cluster \
  --name=\"$CLUSTER_DOMAIN_NAME\" \
  --state=\"s3://$EXISTING_S3_BUCKET\" \
  --yes" $MGMT_USER
 
if sudo su -c "kubectl get namespace cert-manager >/dev/null 2>&1" $MGMT_USER; then
  sudo su -c "kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s" $MGMT_USER
fi
 
for attempt in $(seq 1 30); do
  if sudo su -c "kubectl -n kube-system get deployment aws-load-balancer-controller >/dev/null 2>&1" $MGMT_USER; then
    break
  fi
  sleep 10
done
 
if ! sudo su -c "kubectl -n kube-system get deployment aws-load-balancer-controller >/dev/null 2>&1" $MGMT_USER; then
  echo "aws-load-balancer-controller deployment was not created in kube-system"
  exit 1
fi
 
echo "Ensuring AWS Load Balancer Controller IAM policy is attached to cluster roles..."
curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.1.0/docs/install/iam_policy.json" -o /tmp/aws-lbc-iam-policy.json
 
LBC_POLICY_ARN=$(aws iam list-policies \
  --scope Local \
  --query "Policies[?PolicyName=='$LBC_POLICY_NAME'] | [0].Arn" \
  --output text)
 
if [ -z "$LBC_POLICY_ARN" ] || [ "$LBC_POLICY_ARN" = "None" ]; then
  LBC_POLICY_ARN=$(aws iam create-policy \
    --policy-name "$LBC_POLICY_NAME" \
    --policy-document file:///tmp/aws-lbc-iam-policy.json \
    --query 'Policy.Arn' \
    --output text)
fi
 
for cluster_role in "masters.$CLUSTER_DOMAIN_NAME" "nodes.$CLUSTER_DOMAIN_NAME"; do
  if ! aws iam list-attached-role-policies \
    --role-name "$cluster_role" \
    --query "AttachedPolicies[?PolicyArn=='$LBC_POLICY_ARN'] | [0].PolicyArn" \
    --output text | grep -q "$LBC_POLICY_ARN"; then
    aws iam attach-role-policy --role-name "$cluster_role" --policy-arn "$LBC_POLICY_ARN"
  fi
done
 
sudo su -c "kubectl -n kube-system rollout restart deployment aws-load-balancer-controller" $MGMT_USER
 
for attempt in $(seq 1 90); do
  AVAILABLE_REPLICAS=$(sudo su -c "kubectl -n kube-system get deployment aws-load-balancer-controller -o jsonpath='{.status.availableReplicas}'" $MGMT_USER 2>/dev/null || true)
  DESIRED_REPLICAS=$(sudo su -c "kubectl -n kube-system get deployment aws-load-balancer-controller -o jsonpath='{.spec.replicas}'" $MGMT_USER 2>/dev/null || true)
 
  if [ -n "$AVAILABLE_REPLICAS" ] && [ -n "$DESIRED_REPLICAS" ] && [ "$AVAILABLE_REPLICAS" = "$DESIRED_REPLICAS" ]; then
    break
  fi
 
  sleep 10
done
 
AVAILABLE_REPLICAS=$(sudo su -c "kubectl -n kube-system get deployment aws-load-balancer-controller -o jsonpath='{.status.availableReplicas}'" $MGMT_USER 2>/dev/null || true)
DESIRED_REPLICAS=$(sudo su -c "kubectl -n kube-system get deployment aws-load-balancer-controller -o jsonpath='{.spec.replicas}'" $MGMT_USER 2>/dev/null || true)
 
if [ -z "$AVAILABLE_REPLICAS" ] || [ -z "$DESIRED_REPLICAS" ] || [ "$AVAILABLE_REPLICAS" != "$DESIRED_REPLICAS" ]; then
  echo "aws-load-balancer-controller did not reach the desired available replicas"
  sudo su -c "kubectl -n kube-system get deployment aws-load-balancer-controller -o wide" $MGMT_USER || true
  sudo su -c "kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller -o wide" $MGMT_USER || true
  exit 1
fi
 
sudo su -c "kops validate cluster \
  --name=\"$CLUSTER_DOMAIN_NAME\" \
  --state=\"s3://$EXISTING_S3_BUCKET\" \
  --wait 20m" $MGMT_USER
 
 
echo "--- Initializing Istio via Helm: $(date) ---"
sudo su -c "mkdir -p $TARGET_DIRECTORY" $MGMT_USER
cd $TARGET_DIRECTORY
 
echo "Installing Istio..."
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
sleep 5
sudo chown -R $MGMT_USER:$MGMT_USER "istio-$ISTIO_VERSION"
cd "istio-$ISTIO_VERSION"
export PATH=$PWD/bin:$PATH
echo "export PATH=/home/$MGMT_USER/istio-$ISTIO_VERSION/istio-$ISTIO_VERSION/bin:\$PATH" >> /home/$MGMT_USER/.bashrc
export KUBECONFIG=$KUBERNETES_PATH
istioctl install -y
sleep 10
 
ACM_CERTIFICATE_ARN=$(aws acm list-certificates \
  --region "$AWS_REGION" \
  --certificate-statuses ISSUED \
  --query "CertificateSummaryList[?DomainName=='$CLUSTER_DOMAIN_NAME' || DomainName=='*.$CLUSTER_DOMAIN_NAME'] | [0].CertificateArn" \
  --output text)
 
if [ -z "$ACM_CERTIFICATE_ARN" ] || [ "$ACM_CERTIFICATE_ARN" = "None" ]; then
  echo "No issued ACM certificate found for $CLUSTER_DOMAIN_NAME or *.$CLUSTER_DOMAIN_NAME in $AWS_REGION"
  exit 1
fi
 
echo "Disabling public Istio ingress service for ALB-based ingress..."
sudo su -c "kubectl patch service istio-ingressgateway -n istio-system --type merge -p '{\"spec\":{\"type\":\"ClusterIP\"}}'" $MGMT_USER
 
sudo su -c "kubectl get namespace kubernetes-dashboard >/dev/null 2>&1 || kubectl create namespace kubernetes-dashboard" $MGMT_USER
sudo su -c "kubectl label namespace kubernetes-dashboard istio-injection=enabled" $MGMT_USER
 
sudo su -c "kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml" $MGMT_USER
 
sudo cat <<EOT > /home/$MGMT_USER/service-account.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dashboard-user
  namespace: kubernetes-dashboard
EOT
 
sudo cat <<EOT > /home/$MGMT_USER/role-binding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dashboard-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: dashboard-user
  namespace: kubernetes-dashboard
EOT
 
sudo su -c "kubectl apply -f /home/$MGMT_USER/service-account.yaml" $MGMT_USER
sudo su -c "kubectl apply -f /home/$MGMT_USER/role-binding.yaml" $MGMT_USER
sudo su -c "kubectl -n kubernetes-dashboard create token dashboard-user > /home/$MGMT_USER/dashboard-token.txt" $MGMT_USER
 
sudo su -c "kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd" $MGMT_USER
sudo su -c "kubectl label namespace argocd istio-injection=enabled" $MGMT_USER
 
echo "Installing ArgoCD..."
sudo su -c "kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml" $MGMT_USER
sudo su -c "kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{\"data\":{\"server.insecure\":\"true\"}}'" $MGMT_USER
sudo su -c "kubectl rollout restart deployment argocd-server -n argocd" $MGMT_USER
sudo su -c "kubectl rollout status deployment argocd-server -n argocd --timeout=180s" $MGMT_USER
sleep 20
sudo su -c "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode > /home/$MGMT_USER/argocd-password.txt" $MGMT_USER
sleep 10
 
sudo su -c "kubectl get namespace stage >/dev/null 2>&1 || kubectl create namespace stage" $MGMT_USER
sudo su -c "kubectl label namespace stage istio-injection=enabled" $MGMT_USER
sudo su -c "kubectl get namespace prod >/dev/null 2>&1 || kubectl create namespace prod" $MGMT_USER
sudo su -c "kubectl label namespace prod istio-injection=enabled" $MGMT_USER
 
sudo su -c "kubectl apply -f /home/$MGMT_USER/istio-$ISTIO_VERSION/istio-$ISTIO_VERSION/samples/addons" $MGMT_USER
 
echo "Preparing services for ALB ingress..."
sudo su -c "kubectl patch service kubernetes-dashboard -n kubernetes-dashboard --type merge -p '{\"spec\":{\"type\":\"NodePort\"}}'" $MGMT_USER
sudo su -c "kubectl patch service argocd-server -n argocd --type merge -p '{\"spec\":{\"type\":\"NodePort\"}}'" $MGMT_USER
sudo su -c "kubectl patch service prometheus -n istio-system --type merge -p '{\"spec\":{\"type\":\"NodePort\"}}'" $MGMT_USER
sudo su -c "kubectl patch service grafana -n istio-system --type merge -p '{\"spec\":{\"type\":\"NodePort\"}}'" $MGMT_USER
sudo su -c "kubectl patch service kiali -n istio-system --type merge -p '{\"spec\":{\"type\":\"NodePort\"}}'" $MGMT_USER
sudo su -c "kubectl patch service tracing -n istio-system --type merge -p '{\"spec\":{\"type\":\"NodePort\"}}'" $MGMT_USER
sudo su -c "kubectl patch service zipkin -n istio-system --type merge -p '{\"spec\":{\"type\":\"NodePort\"}}'" $MGMT_USER
 
if sudo su -c "kubectl get service frontend -n stage >/dev/null 2>&1" $MGMT_USER; then
  sudo su -c "kubectl patch service frontend -n stage --type merge -p '{\"spec\":{\"type\":\"NodePort\"}}'" $MGMT_USER
fi
 
if sudo su -c "kubectl get service frontend -n prod >/dev/null 2>&1" $MGMT_USER; then
  sudo su -c "kubectl patch service frontend -n prod --type merge -p '{\"spec\":{\"type\":\"NodePort\"}}'" $MGMT_USER
fi
 
echo "Creating shared ALB ingress resources..."
sudo cat <<EOT > /home/$MGMT_USER/alb-ingressclass.yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
spec:
  controller: ingress.k8s.aws/alb
EOT
 
sudo cat <<EOT > /home/$MGMT_USER/dashboard-alb-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dashboard-alb
  namespace: kubernetes-dashboard
  annotations:
    alb.ingress.kubernetes.io/group.name: platform-public
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: instance
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: "$ACM_CERTIFICATE_ARN"
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/backend-protocol: HTTPS
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTPS
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/success-codes: "200-399"
spec:
  ingressClassName: alb
  rules:
  - host: dashboard.$CLUSTER_DOMAIN_NAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kubernetes-dashboard
            port:
              number: 443
EOT
 
sudo cat <<EOT > /home/$MGMT_USER/argocd-alb-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-alb
  namespace: argocd
  annotations:
    alb.ingress.kubernetes.io/group.name: platform-public
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: instance
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: "$ACM_CERTIFICATE_ARN"
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/success-codes: "200-399"
spec:
  ingressClassName: alb
  rules:
  - host: argocd.$CLUSTER_DOMAIN_NAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOT
 
sudo cat <<EOT > /home/$MGMT_USER/observability-alb-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: observability-alb
  namespace: istio-system
  annotations:
    alb.ingress.kubernetes.io/group.name: platform-public
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: instance
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: "$ACM_CERTIFICATE_ARN"
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/success-codes: "200-399"
spec:
  ingressClassName: alb
  rules:
  - host: prometheus.$CLUSTER_DOMAIN_NAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: prometheus
            port:
              number: 9090
  - host: grafana.$CLUSTER_DOMAIN_NAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 3000
  - host: kiali.$CLUSTER_DOMAIN_NAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kiali
            port:
              number: 20001
  - host: jaeger.$CLUSTER_DOMAIN_NAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: tracing
            port:
              number: 80
  - host: zipkin.$CLUSTER_DOMAIN_NAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: zipkin
            port:
              number: 9411
EOT
 
sudo su -c "kubectl apply -f /home/$MGMT_USER/alb-ingressclass.yaml" $MGMT_USER
sudo su -c "kubectl apply -f /home/$MGMT_USER/dashboard-alb-ingress.yaml" $MGMT_USER
sudo su -c "kubectl apply -f /home/$MGMT_USER/argocd-alb-ingress.yaml" $MGMT_USER
sudo su -c "kubectl apply -f /home/$MGMT_USER/observability-alb-ingress.yaml" $MGMT_USER
 
echo "Waiting for ALB hostname..."
INGRESS_LB_HOSTNAME=""
for attempt in $(seq 1 60); do
  INGRESS_LB_HOSTNAME=$(sudo su -c "kubectl -n kubernetes-dashboard get ingress dashboard-alb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'" $MGMT_USER || true)
  if [ -n "$INGRESS_LB_HOSTNAME" ]; then
    break
  fi
  sleep 10
done
 
if [ -z "$INGRESS_LB_HOSTNAME" ]; then
  echo "Timed out waiting for ALB ingress hostname"
  exit 1
fi
 
INGRESS_LB_ZONE_ID=""
for attempt in $(seq 1 12); do
  INGRESS_LB_ZONE_ID=$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --query "LoadBalancers[?DNSName=='$INGRESS_LB_HOSTNAME'] | [0].CanonicalHostedZoneId" \
    --output text 2>/dev/null || true)
 
  if [ -n "$INGRESS_LB_ZONE_ID" ] && [ "$INGRESS_LB_ZONE_ID" != "None" ]; then
    break
  fi
 
  sleep 10
done
 
if [ -z "$INGRESS_LB_ZONE_ID" ] || [ "$INGRESS_LB_ZONE_ID" = "None" ]; then
  echo "Failed to determine Route53 alias zone ID for ALB $INGRESS_LB_HOSTNAME"
  exit 1
fi
 
echo "Creating Route53 alias records for ALB hostnames..."
for service_host in "$${SERVICE_HOSTS[@]}"; do
  record_name="$${service_host}.$${CLUSTER_DOMAIN_NAME}"
  cat >/tmp/route53-alias-$${service_host}.json <<EOT
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$${record_name}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "$${INGRESS_LB_ZONE_ID}",
          "DNSName": "$${INGRESS_LB_HOSTNAME}",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOT
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch file:///tmp/route53-alias-$${service_host}.json
done
 
export HOME="/home/$MGMT_USER"
export ARGOCD_CONFIG_DIR="$HOME/.config/argocd"
mkdir -p "$ARGOCD_CONFIG_DIR"
 
echo "Waiting for Argo CD domain to become reachable..."
for attempt in $(seq 1 60); do
  if curl -ksSf "https://$ARGOCD_DOMAIN/" >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
 
if ! curl -ksSf "https://$ARGOCD_DOMAIN/" >/dev/null 2>&1; then
  echo "Argo CD domain $ARGOCD_DOMAIN did not become reachable"
  exit 1
fi
 
ARGOCD_PASSWORD=$(cat /home/$MGMT_USER/argocd-password.txt)
argocd login "$ARGOCD_DOMAIN" --username admin --password "$ARGOCD_PASSWORD" --insecure
 
GITHUB_SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$GITHUB_CREDENTIALS_SECRET_ARN" \
  --query SecretString \
  --output text)
GITHUB_USERNAME=$(printf '%s' "$GITHUB_SECRET_JSON" | jq -r '.username')
GITHUB_PASSWORD=$(printf '%s' "$GITHUB_SECRET_JSON" | jq -r '.password')
 
argocd repo add https://github.com/CloudHight/set1-microserviceapp.git \
  --username "$GITHUB_USERNAME" \
  --password "$GITHUB_PASSWORD" \
  --upsert
 
argocd app create stage \
  --repo https://github.com/CloudHight/set1-microserviceapp.git \
  --path . \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace stage \
  --revision stage \
  --sync-policy automated \
  --auto-prune \
  --self-heal
sleep 10
 
argocd app create prod \
  --repo https://github.com/CloudHight/set1-microserviceapp.git \
  --path . \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace prod \
  --revision main \
  --sync-policy automated \
  --auto-prune \
  --self-heal
sleep 10
 
argocd app sync stage
sleep 20
 
argocd app sync prod
sleep 20
 
if sudo su -c "kubectl get service frontend -n stage >/dev/null 2>&1" $MGMT_USER; then
  sudo cat <<EOT > /home/$MGMT_USER/stage-alb-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: stage-alb
  namespace: stage
  annotations:
    alb.ingress.kubernetes.io/group.name: platform-public
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: instance
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: "$ACM_CERTIFICATE_ARN"
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/success-codes: "200-399"
spec:
  ingressClassName: alb
  rules:
  - host: stage.$CLUSTER_DOMAIN_NAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 80
EOT
  sudo su -c "kubectl apply -f /home/$MGMT_USER/stage-alb-ingress.yaml" $MGMT_USER
fi
 
if sudo su -c "kubectl get service frontend -n prod >/dev/null 2>&1" $MGMT_USER; then
  sudo cat <<EOT > /home/$MGMT_USER/prod-alb-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prod-alb
  namespace: prod
  annotations:
    alb.ingress.kubernetes.io/group.name: platform-public
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: instance
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: "$ACM_CERTIFICATE_ARN"
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/success-codes: "200-399"
spec:
  ingressClassName: alb
  rules:
  - host: prod.$CLUSTER_DOMAIN_NAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 80
EOT
  sudo su -c "kubectl apply -f /home/$MGMT_USER/prod-alb-ingress.yaml" $MGMT_USER
fi
 
echo "--- Bootstrap Completed: $(date) ---"
EOF
}