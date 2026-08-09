#!/bin/bash

set -u

REGION="us-east-1"
CLUSTER="mern-eks"
ADDON="amazon-cloudwatch-observability"
NODEGROUP="mern-workers"
REPORT="$HOME/SampleMERNwithMicroservices/phase4a-cloudwatch-diagnosis.txt"

exec > >(tee "$REPORT") 2>&1

echo
echo "=============================================================="
echo " CLOUDWATCH OBSERVABILITY DIAGNOSTIC REPORT"
echo "=============================================================="
echo "Date    : $(date)"
echo "Region  : ${REGION}"
echo "Cluster : ${CLUSTER}"
echo

echo "=============================================================="
echo "1. ADD-ON STATUS AND HEALTH"
echo "=============================================================="

aws eks describe-addon \
    --cluster-name "${CLUSTER}" \
    --addon-name "${ADDON}" \
    --region "${REGION}" \
    --query 'addon.{Status:status,Version:addonVersion,Health:health,ServiceAccount:serviceAccountRoleArn}' \
    --output json

echo

echo "=============================================================="
echo "2. FULL ADD-ON HEALTH"
echo "=============================================================="

aws eks describe-addon \
    --cluster-name "${CLUSTER}" \
    --addon-name "${ADDON}" \
    --region "${REGION}" \
    --query 'addon.health' \
    --output json

echo

echo "=============================================================="
echo "3. CLOUDWATCH NAMESPACE"
echo "=============================================================="

kubectl get namespace amazon-cloudwatch 2>/dev/null || true

echo

echo "=============================================================="
echo "4. ALL CLOUDWATCH PODS"
echo "=============================================================="

kubectl get pods \
    -n amazon-cloudwatch \
    -o wide 2>/dev/null || true

echo

echo "=============================================================="
echo "5. CLOUDWATCH POD STATUS DETAILS"
echo "=============================================================="

kubectl get pods \
    -n amazon-cloudwatch \
    -o json 2>/dev/null |
jq -r '
.items[] |
[
  .metadata.name,
  .status.phase,
  (
    [.status.containerStatuses[]? |
      "\(.name)=\(.state.waiting.reason // .state.terminated.reason // "Running") exit=\(.state.terminated.exitCode // "")"
    ] | join("; ")
  )
] | @tsv
' 2>/dev/null || true

echo

echo "=============================================================="
echo "6. CLOUDWATCH AGENT LOGS"
echo "=============================================================="

AGENT_PODS=$(kubectl get pods \
    -n amazon-cloudwatch \
    -l app.kubernetes.io/name=cloudwatch-agent \
    -o name 2>/dev/null || true)

if [[ -n "${AGENT_PODS}" ]]; then
    while read -r POD; do
        echo
        echo "----- ${POD} -----"
        kubectl logs \
            -n amazon-cloudwatch \
            "${POD}" \
            --all-containers \
            --tail=100 2>&1 || true
    done <<< "${AGENT_PODS}"
else
    echo "No cloudwatch-agent pods found using expected label."
fi

echo

echo "=============================================================="
echo "7. CLOUDWATCH POD EVENTS"
echo "=============================================================="

kubectl get events \
    -n amazon-cloudwatch \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -100 || true

echo

echo "=============================================================="
echo "8. DAEMONSETS"
echo "=============================================================="

kubectl get daemonsets \
    -n amazon-cloudwatch \
    -o wide 2>/dev/null || true

echo

echo "=============================================================="
echo "9. DEPLOYMENTS"
echo "=============================================================="

kubectl get deployments \
    -n amazon-cloudwatch \
    -o wide 2>/dev/null || true

echo

echo "=============================================================="
echo "10. CLOUDWATCH AGENT CUSTOM RESOURCE"
echo "=============================================================="

kubectl get amazoncloudwatchagent \
    -A \
    -o yaml 2>/dev/null || true

echo

echo "=============================================================="
echo "11. CLOUDWATCH SERVICE ACCOUNT"
echo "=============================================================="

kubectl get serviceaccount \
    cloudwatch-agent \
    -n amazon-cloudwatch \
    -o yaml 2>/dev/null || true

echo

echo "=============================================================="
echo "12. POD IDENTITY AGENT"
echo "=============================================================="

kubectl get pods \
    -n kube-system \
    -l app.kubernetes.io/name=eks-pod-identity-agent \
    -o wide 2>/dev/null || true

echo

echo "=============================================================="
echo "13. EKS ADD-ONS"
echo "=============================================================="

aws eks list-addons \
    --cluster-name "${CLUSTER}" \
    --region "${REGION}" \
    --output table

echo

echo "=============================================================="
echo "14. NODE RESOURCES"
echo "=============================================================="

kubectl top nodes 2>/dev/null || true

echo

kubectl describe nodes 2>/dev/null |
grep -A12 -E '^Allocated resources:|^Capacity:|^Allocatable:' \
|| true

echo

echo "=============================================================="
echo "15. NODE MEMORY / CPU"
echo "=============================================================="

NODE=$(kubectl get nodes \
    -o jsonpath='{.items[0].metadata.name}')

echo "Node: ${NODE}"

kubectl describe node "${NODE}" |
grep -A12 "Allocated resources:" || true

echo

echo "=============================================================="
echo "16. NODEGROUP IAM ROLE"
echo "=============================================================="

NODE_ROLE_ARN=$(aws eks describe-nodegroup \
    --cluster-name "${CLUSTER}" \
    --nodegroup-name "${NODEGROUP}" \
    --region "${REGION}" \
    --query 'nodegroup.nodeRole' \
    --output text)

NODE_ROLE_NAME="${NODE_ROLE_ARN##*/}"

echo "Role ARN : ${NODE_ROLE_ARN}"
echo "Role Name: ${NODE_ROLE_NAME}"

echo

echo "=============================================================="
echo "17. NODE IAM POLICIES"
echo "=============================================================="

aws iam list-attached-role-policies \
    --role-name "${NODE_ROLE_NAME}" \
    --output table

echo

echo "=============================================================="
echo "18. CLOUDWATCH POLICY CHECK"
echo "=============================================================="

aws iam list-attached-role-policies \
    --role-name "${NODE_ROLE_NAME}" \
    --query "AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy']" \
    --output table

echo

echo "=============================================================="
echo "19. OIDC PROVIDER"
echo "=============================================================="

aws eks describe-cluster \
    --name "${CLUSTER}" \
    --region "${REGION}" \
    --query 'cluster.identity.oidc.issuer' \
    --output text

echo

echo "=============================================================="
echo "20. POD IDENTITY ASSOCIATIONS"
echo "=============================================================="

aws eks list-pod-identity-associations \
    --cluster-name "${CLUSTER}" \
    --region "${REGION}" \
    --output table 2>/dev/null || true

echo

echo "=============================================================="
echo "21. CLOUDWATCH ADD-ON COMPATIBLE VERSIONS"
echo "=============================================================="

aws eks describe-addon-versions \
    --addon-name "${ADDON}" \
    --kubernetes-version 1.34 \
    --region "${REGION}" \
    --query 'addons[].addonVersions[].{Version:addonVersion,Architecture:architecture,Default:compatibilities[0].defaultVersion}' \
    --output table 2>/dev/null || true

echo

echo "=============================================================="
echo "22. NETWORK TEST FROM NODE"
echo "=============================================================="

echo "Testing CloudWatch endpoint:"
curl -I \
    --max-time 10 \
    "https://monitoring.${REGION}.amazonaws.com" \
    2>&1 || true

echo

echo "Testing CloudWatch Logs endpoint:"
curl -I \
    --max-time 10 \
    "https://logs.${REGION}.amazonaws.com" \
    2>&1 || true

echo

echo "=============================================================="
echo "23. FINAL DIAGNOSIS HINTS"
echo "=============================================================="

echo
echo "Look specifically for:"
echo
echo "  OOMKilled"
echo "  CrashLoopBackOff"
echo "  Pending"
echo "  ImagePullBackOff"
echo "  AccessDenied"
echo "  AccessDeniedException"
echo "  cloudwatch:PutMetricData"
echo "  logs:CreateLogGroup"
echo "  logs:PutLogEvents"
echo "  pods.eks.amazonaws.com"
echo "  FailedScheduling"
echo
echo "=============================================================="
echo "DIAGNOSTIC REPORT COMPLETE"
echo "=============================================================="
echo
echo "Report:"
echo "${REPORT}"
