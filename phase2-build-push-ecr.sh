#!/bin/bash

set -euo pipefail

REGION="us-east-1"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

PROJECT_ROOT="$(pwd)"

HELLO_DIR="$PROJECT_ROOT/backend/helloService"
PROFILE_DIR="$PROJECT_ROOT/backend/profileService"
FRONTEND_DIR="$PROJECT_ROOT/frontend"

HELLO_REPO="hello-service"
PROFILE_REPO="profile-service"
FRONTEND_REPO="mern-frontend"

TAG="v1"

echo
echo "=========================================================="
echo " PHASE 2 - BUILD APPLICATION IMAGES + PUSH TO ECR"
echo "=========================================================="
echo "AWS Account : $ACCOUNT_ID"
echo "AWS Region  : $REGION"
echo "Project     : $PROJECT_ROOT"
echo

############################################################
# PRECHECKS
############################################################

echo "=========================================================="
echo "1. PRECHECKS"
echo "=========================================================="

aws sts get-caller-identity >/dev/null

command -v docker >/dev/null
command -v aws >/dev/null
command -v npm >/dev/null
command -v node >/dev/null

docker info >/dev/null

echo "All required tools available."
echo

############################################################
# VERIFY PROJECT
############################################################

echo "=========================================================="
echo "2. VERIFY APPLICATION"
echo "=========================================================="

test -f "$HELLO_DIR/package.json"
test -f "$HELLO_DIR/index.js"

test -f "$PROFILE_DIR/package.json"
test -f "$PROFILE_DIR/index.js"

test -f "$FRONTEND_DIR/package.json"

echo "Application structure verified."
echo

############################################################
# CREATE HELLO SERVICE DOCKERFILE
############################################################

echo "=========================================================="
echo "3. CREATE HELLO SERVICE DOCKERFILE"
echo "=========================================================="

cat > "$HELLO_DIR/Dockerfile" <<'DOCKERFILE'
FROM node:20-alpine

WORKDIR /app

COPY package*.json ./

RUN npm ci --omit=dev

COPY index.js ./

ENV NODE_ENV=production
ENV PORT=3001

EXPOSE 3001

USER node

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3001/health || exit 1

CMD ["node", "index.js"]
DOCKERFILE

echo "Created:"
echo "$HELLO_DIR/Dockerfile"
echo

############################################################
# CREATE PROFILE SERVICE DOCKERFILE
############################################################

echo "=========================================================="
echo "4. CREATE PROFILE SERVICE DOCKERFILE"
echo "=========================================================="

cat > "$PROFILE_DIR/Dockerfile" <<'DOCKERFILE'
FROM node:20-alpine

WORKDIR /app

COPY package*.json ./

RUN npm ci --omit=dev

COPY index.js ./

ENV NODE_ENV=production
ENV PORT=3002

EXPOSE 3002

USER node

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3002/health || exit 1

CMD ["node", "index.js"]
DOCKERFILE

echo "Created:"
echo "$PROFILE_DIR/Dockerfile"
echo

############################################################
# CREATE FRONTEND DOCKERFILE
############################################################

echo "=========================================================="
echo "5. CREATE FRONTEND DOCKERFILE"
echo "=========================================================="

cat > "$FRONTEND_DIR/Dockerfile" <<'DOCKERFILE'
FROM node:20-alpine AS build

WORKDIR /app

COPY package*.json ./

RUN npm ci

COPY . .

RUN npm run build

FROM nginx:alpine

COPY --from=build /app/build /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
DOCKERFILE

echo "Created:"
echo "$FRONTEND_DIR/Dockerfile"
echo

############################################################
# CREATE .dockerignore FILES
############################################################

echo "=========================================================="
echo "6. CREATE DOCKERIGNORE FILES"
echo "=========================================================="

for DIR in "$HELLO_DIR" "$PROFILE_DIR" "$FRONTEND_DIR"; do

cat > "$DIR/.dockerignore" <<'DOCKERIGNORE'
node_modules
npm-debug.log
.git
.gitignore
.env
.env.*
Dockerfile
README.md
coverage
build
DOCKERIGNORE

done

echo "Docker ignore files created."
echo

############################################################
# INSTALL DEPENDENCIES
############################################################

echo "=========================================================="
echo "7. VERIFY NPM DEPENDENCIES"
echo "=========================================================="

cd "$HELLO_DIR"
npm ci

cd "$PROFILE_DIR"
npm ci

cd "$FRONTEND_DIR"
npm ci

echo
echo "npm dependency installation completed."
echo

############################################################
# BUILD HELLO SERVICE
############################################################

echo "=========================================================="
echo "8. BUILD HELLO SERVICE IMAGE"
echo "=========================================================="

cd "$HELLO_DIR"

docker build \
  --pull \
  -t "${HELLO_REPO}:${TAG}" \
  .

echo

############################################################
# BUILD PROFILE SERVICE
############################################################

echo "=========================================================="
echo "9. BUILD PROFILE SERVICE IMAGE"
echo "=========================================================="

cd "$PROFILE_DIR"

docker build \
  --pull \
  -t "${PROFILE_REPO}:${TAG}" \
  .

echo

############################################################
# BUILD FRONTEND
############################################################

echo "=========================================================="
echo "10. BUILD FRONTEND IMAGE"
echo "=========================================================="

cd "$FRONTEND_DIR"

docker build \
  --pull \
  -t "${FRONTEND_REPO}:${TAG}" \
  .

echo

############################################################
# VERIFY IMAGES
############################################################

echo "=========================================================="
echo "11. LOCAL IMAGE VERIFICATION"
echo "=========================================================="

docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}" | grep -E "hello-service|profile-service|mern-frontend" || true

echo

############################################################
# CREATE ECR REPOSITORIES
############################################################

echo "=========================================================="
echo "12. CREATE ECR REPOSITORIES"
echo "=========================================================="

for REPO in \
    "$HELLO_REPO" \
    "$PROFILE_REPO" \
    "$FRONTEND_REPO"
do

    echo "Checking ECR repository: $REPO"

    if aws ecr describe-repositories \
        --repository-names "$REPO" \
        --region "$REGION" >/dev/null 2>&1
    then
        echo "Already exists: $REPO"
    else
        aws ecr create-repository \
            --repository-name "$REPO" \
            --image-scanning-configuration scanOnPush=true \
            --region "$REGION" >/dev/null

        echo "Created: $REPO"
    fi

done

echo

############################################################
# ECR LOGIN
############################################################

echo "=========================================================="
echo "13. ECR DOCKER LOGIN"
echo "=========================================================="

aws ecr get-login-password \
    --region "$REGION" |
docker login \
    --username AWS \
    --password-stdin \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo

############################################################
# TAG IMAGES
############################################################

echo "=========================================================="
echo "14. TAG IMAGES"
echo "=========================================================="

docker tag \
    "${HELLO_REPO}:${TAG}" \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${HELLO_REPO}:${TAG}"

docker tag \
    "${PROFILE_REPO}:${TAG}" \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${PROFILE_REPO}:${TAG}"

docker tag \
    "${FRONTEND_REPO}:${TAG}" \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${FRONTEND_REPO}:${TAG}"

############################################################
# PUSH IMAGES
############################################################

echo "=========================================================="
echo "15. PUSH IMAGES TO ECR"
echo "=========================================================="

docker push \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${HELLO_REPO}:${TAG}"

docker push \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${PROFILE_REPO}:${TAG}"

docker push \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${FRONTEND_REPO}:${TAG}"

############################################################
# VERIFY ECR
############################################################

echo "=========================================================="
echo "16. VERIFY ECR IMAGES"
echo "=========================================================="

for REPO in \
    "$HELLO_REPO" \
    "$PROFILE_REPO" \
    "$FRONTEND_REPO"
do

    echo
    echo "Repository: $REPO"

    aws ecr describe-images \
        --repository-name "$REPO" \
        --region "$REGION" \
        --query 'imageDetails[].{Tag:imageTags[0],Digest:imageDigest,Size:imageSizeInBytes}' \
        --output table

done

############################################################
# FINAL REPORT
############################################################

REPORT="$PROJECT_ROOT/phase2-ecr-report.txt"

{
echo "=========================================================="
echo "PHASE 2 ECR REPORT"
echo "=========================================================="
echo "Date       : $(date)"
echo "AWS Account: $ACCOUNT_ID"
echo "AWS Region : $REGION"
echo
echo "ECR Repositories:"
echo
echo "$HELLO_REPO"
echo "$PROFILE_REPO"
echo "$FRONTEND_REPO"
echo
echo "Images:"
echo
echo "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${HELLO_REPO}:${TAG}"
echo "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${PROFILE_REPO}:${TAG}"
echo "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${FRONTEND_REPO}:${TAG}"
echo
echo "ECR verification:"
aws ecr describe-repositories \
    --region "$REGION" \
    --query 'repositories[].repositoryUri' \
    --output table
echo
echo "=========================================================="
echo "PHASE 2 COMPLETE"
echo "=========================================================="
} | tee "$REPORT"

echo
echo "=========================================================="
echo " SUCCESS: IMAGES BUILT AND PUSHED TO ECR"
echo "=========================================================="
echo
echo "Report:"
echo "$REPORT"
echo
