#!/bin/bash

set -Eeuo pipefail

REGION="us-east-1"
CLUSTER="mern-eks"
NAMESPACE="mern"
RELEASE="mern-app"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

if [[ -z "${ACCOUNT_ID}" || "${ACCOUNT_ID}" == "None" ]]; then
    echo "ERROR: AWS account ID could not be determined."
    exit 1
fi

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

PROJECT_ROOT="$(pwd)"
CHART_DIR="${PROJECT_ROOT}/helm/mern-app"

HELLO_IMAGE="${REGISTRY}/hello-service"
PROFILE_IMAGE="${REGISTRY}/profile-service"
FRONTEND_IMAGE="${REGISTRY}/mern-frontend"

echo
echo "============================================================"
echo " PHASE 3 - EKS / HELM DEPLOYMENT"
echo "============================================================"
echo "AWS Account : ${ACCOUNT_ID}"
echo "AWS Region  : ${REGION}"
echo "Cluster     : ${CLUSTER}"
echo "Namespace   : ${NAMESPACE}"
echo "Registry    : ${REGISTRY}"
echo

echo "============================================================"
echo "1. AWS / EKS VALIDATION"
echo "============================================================"

aws sts get-caller-identity

echo
echo "EKS:"
aws eks describe-cluster \
    --name "${CLUSTER}" \
    --region "${REGION}" \
    --query 'cluster.{Name:name,Status:status,Version:version}' \
    --output table

echo
echo "Kubernetes nodes:"
kubectl get nodes

echo
echo "AWS/EKS validation PASSED."

echo "============================================================"
echo "2. ECR VALIDATION"
echo "============================================================"

aws ecr describe-images \
    --repository-name hello-service \
    --region "${REGION}" \
    --query 'imageDetails[].imageTags' \
    --output table

aws ecr describe-images \
    --repository-name profile-service \
    --region "${REGION}" \
    --query 'imageDetails[].imageTags' \
    --output table

aws ecr describe-images \
    --repository-name mern-frontend \
    --region "${REGION}" \
    --query 'imageDetails[].imageTags' \
    --output table

echo
echo "ECR validation PASSED."

echo "============================================================"
echo "3. UPDATE FRONTEND"
echo "============================================================"

cp frontend/src/components/Home.js \
   frontend/src/components/Home.js.backup

python3 <<'PY'
from pathlib import Path

p = Path("frontend/src/components/Home.js")
s = p.read_text()

s = s.replace(
    "http://localhost:3001/",
    "/api/hello"
)

s = s.replace(
    "http://localhost:3002/fetchUser",
    "/api/profile/fetchUser"
)

p.write_text(s)
PY

echo
echo "Frontend URLs after modification:"
grep -nE "localhost|api/hello|api/profile" \
    frontend/src/components/Home.js || true

echo

echo "============================================================"
echo "4. CREATE NGINX CONFIG"
echo "============================================================"

cat > frontend/nginx.conf <<'NGINX'
server {
    listen 80;

    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    location /api/hello {
        proxy_pass http://hello-service:3001/;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /api/profile {
        proxy_pass http://profile-service:3002/;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX

echo "Nginx configuration created."

echo "============================================================"
echo "5. CREATE FRONTEND DOCKERFILE"
echo "============================================================"

cat > frontend/Dockerfile <<'DOCKERFILE'
FROM node:20-alpine AS build

WORKDIR /app

COPY package*.json ./

RUN npm ci

COPY . .

RUN npm run build

FROM nginx:alpine

COPY --from=build /app/build /usr/share/nginx/html

COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

HEALTHCHECK --interval=30s \
    --timeout=5s \
    --start-period=10s \
    --retries=3 \
    CMD wget -qO- http://127.0.0.1/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
DOCKERFILE

echo "Frontend Dockerfile created."

echo "============================================================"
echo "6. BUILD FRONTEND V2"
echo "============================================================"

docker build \
    --pull \
    -t "${FRONTEND_IMAGE}:v2" \
    ./frontend

echo
echo "Frontend v2 built successfully."

echo "============================================================"
echo "7. LOGIN TO ECR"
echo "============================================================"

aws ecr get-login-password \
    --region "${REGION}" |
docker login \
    --username AWS \
    --password-stdin \
    "${REGISTRY}"

echo
echo "ECR login successful."

echo "============================================================"
echo "8. PUSH FRONTEND V2"
echo "============================================================"

docker push "${FRONTEND_IMAGE}:v2"

echo
echo "Frontend v2 pushed successfully."

echo "============================================================"
echo "9. CREATE NAMESPACE"
echo "============================================================"

kubectl create namespace "${NAMESPACE}" \
    --dry-run=client \
    -o yaml |
kubectl apply -f -

echo "Namespace ready."

echo "============================================================"
echo "10. CREATE HELM CHART"
echo "============================================================"

rm -rf "${CHART_DIR}"

mkdir -p "${CHART_DIR}/templates"

cat > "${CHART_DIR}/Chart.yaml" <<'CHART'
apiVersion: v2
name: mern-app
description: MERN Microservices Application
type: application
version: 1.0.0
appVersion: "1.0"
CHART

cat > "${CHART_DIR}/values.yaml" <<VALUES
namespace: ${NAMESPACE}

images:
  hello:
    repository: ${HELLO_IMAGE}
    tag: v1

  profile:
    repository: ${PROFILE_IMAGE}
    tag: v1

  frontend:
    repository: ${FRONTEND_IMAGE}
    tag: v2

mongodb:
  image: mongo:7

replicas:
  hello: 1
  profile: 1
  frontend: 1
  mongodb: 1
VALUES

echo "Helm chart base created."

echo "============================================================"
echo "11. CREATE MONGODB MANIFEST"
echo "============================================================"

cat > "${CHART_DIR}/templates/mongodb.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongodb
  namespace: {{ .Values.namespace }}
  labels:
    app: mongodb
spec:
  replicas: {{ .Values.replicas.mongodb }}
  selector:
    matchLabels:
      app: mongodb
  template:
    metadata:
      labels:
        app: mongodb
    spec:
      containers:
        - name: mongodb
          image: {{ .Values.mongodb.image }}
          ports:
            - containerPort: 27017
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 250m
              memory: 256Mi
          readinessProbe:
            tcpSocket:
              port: 27017
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 27017
            initialDelaySeconds: 30
            periodSeconds: 20

---
apiVersion: v1
kind: Service
metadata:
  name: mongodb
  namespace: {{ .Values.namespace }}
spec:
  type: ClusterIP
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
YAML

echo "MongoDB manifest created."

echo "============================================================"
echo "12. CREATE HELLO SERVICE"
echo "============================================================"

cat > "${CHART_DIR}/templates/hello.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-service
  namespace: {{ .Values.namespace }}
  labels:
    app: hello-service
spec:
  replicas: {{ .Values.replicas.hello }}
  selector:
    matchLabels:
      app: hello-service
  template:
    metadata:
      labels:
        app: hello-service
    spec:
      containers:
        - name: hello-service
          image: "{{ .Values.images.hello.repository }}:{{ .Values.images.hello.tag }}"
          imagePullPolicy: Always
          env:
            - name: NODE_ENV
              value: production
            - name: PORT
              value: "3001"
          ports:
            - containerPort: 3001
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /health
              port: 3001
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 3001
            initialDelaySeconds: 30
            periodSeconds: 20

---
apiVersion: v1
kind: Service
metadata:
  name: hello-service
  namespace: {{ .Values.namespace }}
spec:
  type: ClusterIP
  selector:
    app: hello-service
  ports:
    - port: 3001
      targetPort: 3001
YAML

echo "Hello service manifest created."

echo "============================================================"
echo "13. CREATE PROFILE SERVICE"
echo "============================================================"

cat > "${CHART_DIR}/templates/profile.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: profile-service
  namespace: {{ .Values.namespace }}
  labels:
    app: profile-service
spec:
  replicas: {{ .Values.replicas.profile }}
  selector:
    matchLabels:
      app: profile-service
  template:
    metadata:
      labels:
        app: profile-service
    spec:
      containers:
        - name: profile-service
          image: "{{ .Values.images.profile.repository }}:{{ .Values.images.profile.tag }}"
          imagePullPolicy: Always
          env:
            - name: NODE_ENV
              value: production
            - name: PORT
              value: "3002"
            - name: MONGO_URL
              value: "mongodb://mongodb:27017/mern"
          ports:
            - containerPort: 3002
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /health
              port: 3002
            initialDelaySeconds: 20
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 3002
            initialDelaySeconds: 40
            periodSeconds: 20

---
apiVersion: v1
kind: Service
metadata:
  name: profile-service
  namespace: {{ .Values.namespace }}
spec:
  type: ClusterIP
  selector:
    app: profile-service
  ports:
    - port: 3002
      targetPort: 3002
YAML

echo "Profile service manifest created."

echo "============================================================"
echo "14. CREATE FRONTEND"
echo "============================================================"

cat > "${CHART_DIR}/templates/frontend.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: {{ .Values.namespace }}
  labels:
    app: frontend
spec:
  replicas: {{ .Values.replicas.frontend }}
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: frontend
          image: "{{ .Values.images.frontend.repository }}:{{ .Values.images.frontend.tag }}"
          imagePullPolicy: Always
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 30
            periodSeconds: 20

---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: {{ .Values.namespace }}
spec:
  type: LoadBalancer
  selector:
    app: frontend
  ports:
    - port: 80
      targetPort: 80
YAML

echo "Frontend manifest created."

echo "============================================================"
echo "15. HELM VALIDATION"
echo "============================================================"

helm lint "${CHART_DIR}"

helm template \
    "${RELEASE}" \
    "${CHART_DIR}" \
    --namespace "${NAMESPACE}" \
    >/tmp/mern-rendered.yaml

echo
echo "Helm validation PASSED."

echo "============================================================"
echo "16. DEPLOY HELM RELEASE"
echo "============================================================"

helm upgrade --install \
    "${RELEASE}" \
    "${CHART_DIR}" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --wait \
    --timeout 5m

echo
echo "Helm deployment completed."

echo "============================================================"
echo "17. APPLICATION STATUS"
echo "============================================================"

kubectl get deployments -n "${NAMESPACE}"

echo
kubectl get pods -n "${NAMESPACE}" -o wide

echo
kubectl get services -n "${NAMESPACE}"

echo
helm list -n "${NAMESPACE}"

echo "============================================================"
echo "18. WAIT FOR DEPLOYMENTS"
echo "============================================================"

kubectl rollout status deployment/mongodb \
    -n "${NAMESPACE}" \
    --timeout=180s

kubectl rollout status deployment/hello-service \
    -n "${NAMESPACE}" \
    --timeout=180s

kubectl rollout status deployment/profile-service \
    -n "${NAMESPACE}" \
    --timeout=180s

kubectl rollout status deployment/frontend \
    -n "${NAMESPACE}" \
    --timeout=180s

echo
echo "All deployments are READY."

echo "============================================================"
echo "19. SERVICE DISCOVERY TEST"
echo "============================================================"

kubectl run mern-connectivity-test \
    -n "${NAMESPACE}" \
    --rm \
    -i \
    --restart=Never \
    --image=curlimages/curl:8.16.0 \
    --command -- \
    sh -c '
        echo "HELLO SERVICE:"
        curl -fsS http://hello-service:3001/health
        echo
        echo
        echo "PROFILE SERVICE:"
        curl -fsS http://profile-service:3002/health
        echo
    '

echo
echo "Service discovery test PASSED."

echo "============================================================"
echo "20. FINAL STATUS"
echo "============================================================"

kubectl get pods -n "${NAMESPACE}" -o wide

echo
kubectl get services -n "${NAMESPACE}"

echo
helm list -n "${NAMESPACE}"

echo
echo "============================================================"
echo " PHASE 3 COMPLETE"
echo "============================================================"
echo

REPORT="${PROJECT_ROOT}/phase3-deployment-report.txt"

{
    echo "PHASE 3 DEPLOYMENT REPORT"
    echo
    echo "Date       : $(date)"
    echo "AWS Account: ${ACCOUNT_ID}"
    echo "Region     : ${REGION}"
    echo "Cluster    : ${CLUSTER}"
    echo "Namespace  : ${NAMESPACE}"
    echo
    echo "Nodes:"
    kubectl get nodes -o wide
    echo
    echo "Deployments:"
    kubectl get deployments -n "${NAMESPACE}"
    echo
    echo "Pods:"
    kubectl get pods -n "${NAMESPACE}" -o wide
    echo
    echo "Services:"
    kubectl get services -n "${NAMESPACE}"
    echo
    echo "Helm:"
    helm list -n "${NAMESPACE}"
} | tee "${REPORT}"

echo
echo "Report saved to:"
echo "${REPORT}"
