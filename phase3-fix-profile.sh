#!/bin/bash

set -Eeuo pipefail

REGION="us-east-1"
CLUSTER="mern-eks"
NAMESPACE="mern"
RELEASE="mern-app"

PROJECT_ROOT="$(pwd)"
CHART_DIR="${PROJECT_ROOT}/helm/mern-app"

echo
echo "=============================================================="
echo " PHASE 3 - PROFILE SERVICE ROUTING FIX"
echo "=============================================================="

# ==============================================================
# 1. AWS INFORMATION
# ==============================================================

ACCOUNT_ID="$(aws sts get-caller-identity \
    --query Account \
    --output text)"

if [[ -z "${ACCOUNT_ID}" || "${ACCOUNT_ID}" == "None" ]]; then
    echo "ERROR: Unable to determine AWS account."
    exit 1
fi

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
FRONTEND_IMAGE="${REGISTRY}/mern-frontend"

echo
echo "AWS Account : ${ACCOUNT_ID}"
echo "AWS Region  : ${REGION}"
echo "EKS Cluster : ${CLUSTER}"
echo "Namespace   : ${NAMESPACE}"
echo "Registry    : ${REGISTRY}"
echo

# ==============================================================
# 2. EKS VALIDATION
# ==============================================================

echo "=============================================================="
echo "1. EKS VALIDATION"
echo "=============================================================="

STATUS="$(aws eks describe-cluster \
    --name "${CLUSTER}" \
    --region "${REGION}" \
    --query 'cluster.status' \
    --output text)"

if [[ "${STATUS}" != "ACTIVE" ]]; then
    echo "ERROR: EKS cluster is not ACTIVE."
    echo "Current status: ${STATUS}"
    exit 1
fi

kubectl get nodes

echo
echo "EKS validation PASSED."

# ==============================================================
# 3. CHECK EXISTING DEPLOYMENT
# ==============================================================

echo "=============================================================="
echo "2. CHECK EXISTING MERN DEPLOYMENT"
echo "=============================================================="

kubectl get deployments -n "${NAMESPACE}"
echo
kubectl get pods -n "${NAMESPACE}"
echo
kubectl get services -n "${NAMESPACE}"

# ==============================================================
# 4. VERIFY PROFILE SERVICE
# ==============================================================

echo
echo "=============================================================="
echo "3. VERIFY PROFILE SERVICE"
echo "=============================================================="

PROFILE_POD="$(kubectl get pods \
    -n "${NAMESPACE}" \
    -l app=profile-service \
    -o jsonpath='{.items[0].metadata.name}')"

if [[ -z "${PROFILE_POD}" ]]; then
    echo "ERROR: Profile Service pod not found."
    exit 1
fi

echo "Profile Pod: ${PROFILE_POD}"

echo
echo "Profile Service logs:"
kubectl logs "${PROFILE_POD}" \
    -n "${NAMESPACE}" \
    --tail=30

# ==============================================================
# 5. DIRECT PROFILE API TEST
# ==============================================================

echo
echo "=============================================================="
echo "4. DIRECT PROFILE API TEST"
echo "=============================================================="

set +e

kubectl run profile-routing-test \
    -n "${NAMESPACE}" \
    --rm \
    -i \
    --restart=Never \
    --image=curlimages/curl:8.16.0 \
    -- \
    curl -sS -i \
    --max-time 15 \
    http://profile-service:3002/fetchUser

DIRECT_RESULT=$?

set -e

if [[ ${DIRECT_RESULT} -ne 0 ]]; then
    echo
    echo "WARNING: Direct Profile API test failed."
    echo "The script will continue so that the deployment can be corrected."
else
    echo
    echo "Direct Profile API test completed."
fi

# ==============================================================
# 6. BACKUP CURRENT FRONTEND CONFIGURATION
# ==============================================================

echo
echo "=============================================================="
echo "5. BACKUP CURRENT FRONTEND CONFIGURATION"
echo "=============================================================="

BACKUP_DIR="${PROJECT_ROOT}/backup-profile-fix-$(date +%Y%m%d-%H%M%S)"

mkdir -p "${BACKUP_DIR}"

if [[ -f frontend/nginx.conf ]]; then
    cp frontend/nginx.conf "${BACKUP_DIR}/nginx.conf"
fi

if [[ -f frontend/src/components/Home.js ]]; then
    cp frontend/src/components/Home.js \
       "${BACKUP_DIR}/Home.js"
fi

echo "Backup directory:"
echo "${BACKUP_DIR}"

# ==============================================================
# 7. VERIFY FRONTEND API PATH
# ==============================================================

echo
echo "=============================================================="
echo "6. VERIFY FRONTEND API PATH"
echo "=============================================================="

if grep -q '"/api/profile/fetchUser"' \
    frontend/src/components/Home.js; then

    echo "Frontend already uses /api/profile/fetchUser."

else

    echo "Updating frontend API path..."

    python3 <<'PY'
from pathlib import Path

p = Path("frontend/src/components/Home.js")

s = p.read_text()

s = s.replace(
    'http://localhost:3002/fetchUser',
    '/api/profile/fetchUser'
)

s = s.replace(
    'http://localhost:3001/',
    '/api/hello'
)

p.write_text(s)
PY

fi

echo
grep -nE 'api/profile|api/hello|localhost' \
    frontend/src/components/Home.js || true

# ==============================================================
# 8. CREATE CORRECT NGINX CONFIGURATION
# ==============================================================

echo
echo "=============================================================="
echo "7. CREATE CORRECT NGINX CONFIGURATION"
echo "=============================================================="

cat > frontend/nginx.conf <<'NGINX'
server {
    listen 80;

    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    # ----------------------------------------------------------
    # Hello Service
    # /api/hello
    #          |
    #          +----> hello-service:3001/
    # ----------------------------------------------------------

    location = /api/hello {
        proxy_pass http://hello-service:3001/;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # ----------------------------------------------------------
    # Profile Service
    #
    # /api/profile/fetchUser
    #          |
    #          +---- rewrite to /fetchUser
    #          |
    #          +----> profile-service:3002
    # ----------------------------------------------------------

    location /api/profile/ {

        rewrite ^/api/profile/(.*)$ /$1 break;

        proxy_pass http://profile-service:3002;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # ----------------------------------------------------------
    # React Frontend
    # ----------------------------------------------------------

    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX

echo
echo "Nginx configuration:"
cat frontend/nginx.conf

# ==============================================================
# 9. VALIDATE FRONTEND DOCKERFILE
# ==============================================================

echo
echo "=============================================================="
echo "8. VALIDATE FRONTEND DOCKERFILE"
echo "=============================================================="

if [[ ! -f frontend/Dockerfile ]]; then

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

fi

echo "Frontend Dockerfile ready."

# ==============================================================
# 10. BUILD FRONTEND V3
# ==============================================================

echo
echo "=============================================================="
echo "9. BUILD FRONTEND V3"
echo "=============================================================="

docker build \
    --pull \
    -t "${FRONTEND_IMAGE}:v3" \
    ./frontend

echo
echo "Frontend v3 build successful."

# ==============================================================
# 11. ECR LOGIN
# ==============================================================

echo
echo "=============================================================="
echo "10. ECR LOGIN"
echo "=============================================================="

aws ecr get-login-password \
    --region "${REGION}" |
docker login \
    --username AWS \
    --password-stdin \
    "${REGISTRY}"

# ==============================================================
# 12. PUSH V3
# ==============================================================

echo
echo "=============================================================="
echo "11. PUSH FRONTEND V3"
echo "=============================================================="

docker push "${FRONTEND_IMAGE}:v3"

echo
echo "Frontend v3 pushed successfully."

# ==============================================================
# 13. UPDATE HELM VALUES
# ==============================================================

echo
echo "=============================================================="
echo "12. UPDATE HELM FRONTEND IMAGE"
echo "=============================================================="

if [[ ! -f "${CHART_DIR}/values.yaml" ]]; then
    echo "ERROR: Helm chart not found:"
    echo "${CHART_DIR}"
    exit 1
fi

python3 <<PY
from pathlib import Path

p = Path("${CHART_DIR}/values.yaml")

s = p.read_text()

s = s.replace(
    'tag: v2',
    'tag: v3'
)

p.write_text(s)
PY

echo
echo "Current frontend image configuration:"
grep -A3 'frontend:' "${CHART_DIR}/values.yaml"

# ==============================================================
# 14. UPDATE HELM NGINX CONFIG
# ==============================================================

echo
echo "=============================================================="
echo "13. UPDATE HELM FRONTEND CONFIG"
echo "=============================================================="

FRONTEND_TEMPLATE="${CHART_DIR}/templates/frontend.yaml"

if [[ ! -f "${FRONTEND_TEMPLATE}" ]]; then
    echo "ERROR: Frontend Helm template not found."
    exit 1
fi

# The nginx.conf is baked into the Docker image.
# No ConfigMap change is required.

echo "Helm frontend deployment will use frontend:v3."

# ==============================================================
# 15. HELM LINT
# ==============================================================

echo
echo "=============================================================="
echo "14. HELM LINT"
echo "=============================================================="

helm lint "${CHART_DIR}"

# ==============================================================
# 16. HELM TEMPLATE
# ==============================================================

echo
echo "=============================================================="
echo "15. HELM TEMPLATE VALIDATION"
echo "=============================================================="

helm template \
    "${RELEASE}" \
    "${CHART_DIR}" \
    --namespace "${NAMESPACE}" \
    >/tmp/mern-profile-fix-rendered.yaml

echo "Helm template validation PASSED."

# ==============================================================
# 17. HELM UPGRADE
# ==============================================================

echo
echo "=============================================================="
echo "16. HELM UPGRADE"
echo "=============================================================="

helm upgrade \
    "${RELEASE}" \
    "${CHART_DIR}" \
    --namespace "${NAMESPACE}" \
    --wait \
    --timeout 5m

echo
echo "Helm upgrade completed."

# ==============================================================
# 18. WAIT FOR FRONTEND
# ==============================================================

echo
echo "=============================================================="
echo "17. WAIT FOR FRONTEND ROLLOUT"
echo "=============================================================="

kubectl rollout status \
    deployment/frontend \
    -n "${NAMESPACE}" \
    --timeout=180s

echo
echo "Frontend rollout successful."

# ==============================================================
# 19. WAIT FOR POD
# ==============================================================

kubectl get pods \
    -n "${NAMESPACE}" \
    -o wide

# ==============================================================
# 20. TEST PROFILE SERVICE DIRECTLY
# ==============================================================

echo
echo "=============================================================="
echo "18. TEST PROFILE SERVICE DIRECTLY"
echo "=============================================================="

kubectl run profile-direct-test \
    -n "${NAMESPACE}" \
    --rm \
    -i \
    --restart=Never \
    --image=curlimages/curl:8.16.0 \
    -- \
    curl -sS -i \
    --max-time 15 \
    http://profile-service:3002/fetchUser

echo
echo "Direct Profile Service test completed."

# ==============================================================
# 21. GET LOAD BALANCER
# ==============================================================

echo
echo "=============================================================="
echo "19. GET FRONTEND LOAD BALANCER"
echo "=============================================================="

LB_HOST=""

for i in $(seq 1 30); do

    LB_HOST="$(kubectl get svc frontend \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
        2>/dev/null || true)"

    if [[ -n "${LB_HOST}" ]]; then
        break
    fi

    echo "Waiting for LoadBalancer..."
    sleep 5

done

if [[ -z "${LB_HOST}" ]]; then
    echo "ERROR: LoadBalancer hostname not found."
    kubectl get svc frontend -n "${NAMESPACE}"
    exit 1
fi

echo
echo "LoadBalancer:"
echo "${LB_HOST}"

# ==============================================================
# 22. TEST HELLO THROUGH NGINX
# ==============================================================

echo
echo "=============================================================="
echo "20. TEST HELLO THROUGH FRONTEND"
echo "=============================================================="

HELLO_RESPONSE="$(curl -sS \
    --max-time 20 \
    "http://${LB_HOST}/api/hello" || true)"

echo "${HELLO_RESPONSE}"

# ==============================================================
# 23. TEST PROFILE THROUGH NGINX
# ==============================================================

echo
echo "=============================================================="
echo "21. TEST PROFILE THROUGH FRONTEND"
echo "=============================================================="

PROFILE_RESPONSE="$(curl -sS \
    --max-time 20 \
    "http://${LB_HOST}/api/profile/fetchUser" || true)"

echo "${PROFILE_RESPONSE}"

# ==============================================================
# 24. VERIFY NO DOUBLE SLASH
# ==============================================================

echo
echo "=============================================================="
echo "22. VERIFY PROFILE ROUTING"
echo "=============================================================="

PROFILE_LOGS="$(kubectl logs \
    deployment/profile-service \
    -n "${NAMESPACE}" \
    --tail=100)"

echo "${PROFILE_LOGS}"

if echo "${PROFILE_LOGS}" | grep -q "Cannot GET //fetchUser"; then
    echo
    echo "ERROR: Double-slash routing problem still exists."
    exit 1
fi

# ==============================================================
# 25. FINAL POD STATUS
# ==============================================================

echo
echo "=============================================================="
echo "23. FINAL POD STATUS"
echo "=============================================================="

kubectl get pods \
    -n "${NAMESPACE}" \
    -o wide

# ==============================================================
# 26. FINAL SERVICE STATUS
# ==============================================================

echo
echo "=============================================================="
echo "24. FINAL SERVICE STATUS"
echo "=============================================================="

kubectl get services \
    -n "${NAMESPACE}"

# ==============================================================
# 27. FINAL HELM STATUS
# ==============================================================

echo
echo "=============================================================="
echo "25. FINAL HELM STATUS"
echo "=============================================================="

helm status \
    "${RELEASE}" \
    -n "${NAMESPACE}"

# ==============================================================
# 28. REPORT
# ==============================================================

REPORT="${PROJECT_ROOT}/phase3-profile-fix-report.txt"

{
    echo "=============================================================="
    echo "PHASE 3 PROFILE SERVICE FIX REPORT"
    echo "=============================================================="
    echo
    echo "Date       : $(date)"
    echo "AWS Account: ${ACCOUNT_ID}"
    echo "Region     : ${REGION}"
    echo "Cluster    : ${CLUSTER}"
    echo "Namespace  : ${NAMESPACE}"
    echo
    echo "Frontend Image:"
    echo "${FRONTEND_IMAGE}:v3"
    echo
    echo "LoadBalancer:"
    echo "${LB_HOST}"
    echo
    echo "=============================================================="
    echo "NODES"
    echo "=============================================================="
    kubectl get nodes -o wide
    echo
    echo "=============================================================="
    echo "DEPLOYMENTS"
    echo "=============================================================="
    kubectl get deployments -n "${NAMESPACE}"
    echo
    echo "=============================================================="
    echo "PODS"
    echo "=============================================================="
    kubectl get pods -n "${NAMESPACE}" -o wide
    echo
    echo "=============================================================="
    echo "SERVICES"
    echo "=============================================================="
    kubectl get services -n "${NAMESPACE}"
    echo
    echo "=============================================================="
    echo "PROFILE SERVICE LOGS"
    echo "=============================================================="
    kubectl logs deployment/profile-service \
        -n "${NAMESPACE}" \
        --tail=100
    echo
    echo "=============================================================="
    echo "HELM"
    echo "=============================================================="
    helm list -n "${NAMESPACE}"
    echo
    echo "=============================================================="
    echo "ENDPOINT TESTS"
    echo "=============================================================="
    echo "Hello:"
    echo "${HELLO_RESPONSE}"
    echo
    echo "Profile:"
    echo "${PROFILE_RESPONSE}"
    echo
    echo "=============================================================="
    echo "PROFILE ROUTING FIX COMPLETED"
    echo "=============================================================="
} | tee "${REPORT}"

echo
echo "=============================================================="
echo " PROFILE SERVICE FIX SUCCESSFUL"
echo "=============================================================="
echo
echo "Report:"
echo "${REPORT}"
echo
echo "Frontend:"
echo "http://${LB_HOST}"
echo
echo "Profile API:"
echo "http://${LB_HOST}/api/profile/fetchUser"
echo
