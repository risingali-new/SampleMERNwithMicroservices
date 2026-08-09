#!/bin/bash

set -Eeuo pipefail

REGION="us-east-1"
CLUSTER="mern-eks"
NODEGROUP="mern-workers"
ADDON="amazon-cloudwatch-observability"
NAMESPACE="mern"

REPORT="${HOME}/SampleMERNwithMicroservices/phase4a-cloudwatch-fix-report.txt"

exec > >(tee "${REPORT}") 2>&1

echo
echo "=============================================================="
echo " PHASE 4A - CLOUDWATCH CAPACITY FIX"
echo "=============================================================="
echo "Date       : $(date)"
echo "Region     : ${REGION}"
echo "Cluster    : ${CLUSTER}"
echo "Nodegroup  : ${NODEGROUP}"
echo

# ==============================================================
# 1. VERIFY CLUSTER
# ==============================================================

echo "=============================================================="
echo "1. VERIFY EKS"
echo "=============================================================="

CLUSTER_STATUS="$(aws eks describe-cluster \
    --name "${CLUSTER}" \
    --region "${REGION}" \
    --query 'cluster.status' \
    --output text)"

if [[ "${CLUSTER_STATUS}" != "ACTIVE" ]]; then
    echo "ERROR: EKS cluster is not ACTIVE."
    echo "Status: ${CLUSTER_STATUS}"
    exit 1
fi

echo "EKS Status: ${CLUSTER_STATUS}"

# ==============================================================
# 2. CURRENT NODEGROUP
# ==============================================================

echo
echo "=============================================================="
echo "2. CURRENT NODEGROUP"
echo "=============================================================="

aws eks describe-nodegroup \
    --cluster-name "${CLUSTER}" \
    --nodegroup-name "${NODEGROUP}" \
    --region "${REGION}" \
    --query 'nodegroup.{Status:status,Min:minSize,Max:maxSize,Desired:scalingConfig.desiredSize,InstanceType:instanceTypes[0]}' \
    --output table

CURRENT_DESIRED="$(aws eks describe-nodegroup \
    --cluster-name "${CLUSTER}" \
    --nodegroup-name "${NODEGROUP}" \
    --region "${REGION}" \
    --query 'nodegroup.scalingConfig.desiredSize' \
    --output text)"

MAX_SIZE="$(aws eks describe-nodegroup \
    --cluster-name "${CLUSTER}" \
    --nodegroup-name "${NODEGROUP}" \
    --region "${REGION}" \
    --query 'nodegroup.scalingConfig.maxSize' \
    --output text)"

echo
echo "Current desired nodes : ${CURRENT_DESIRED}"
echo "Maximum nodes         : ${MAX_SIZE}"

if (( MAX_SIZE < 2 )); then
    echo
    echo "ERROR: Nodegroup maximum size is ${MAX_SIZE}."
    echo "Cannot safely scale to two nodes."
    exit 1
fi

# ==============================================================
# 3. SCALE NODEGROUP
# ==============================================================

echo
echo "=============================================================="
echo "3. SCALE WORKER NODEGROUP TO 2"
echo "=============================================================="

if (( CURRENT_DESIRED < 2 )); then

    echo "Scaling ${NODEGROUP}: ${CURRENT_DESIRED} -> 2"

    aws eks update-nodegroup-config \
        --cluster-name "${CLUSTER}" \
        --nodegroup-name "${NODEGROUP}" \
        --region "${REGION}" \
        --scaling-config minSize=1,maxSize="${MAX_SIZE}",desiredSize=2

    echo
    echo "Nodegroup scaling request submitted."

else

    echo "Nodegroup already has desired capacity >= 2."

fi

# ==============================================================
# 4. WAIT FOR NODEGROUP
# ==============================================================

echo
echo "=============================================================="
echo "4. WAIT FOR NODEGROUP TO BECOME ACTIVE"
echo "=============================================================="

for i in $(seq 1 30); do

    STATUS="$(aws eks describe-nodegroup \
        --cluster-name "${CLUSTER}" \
        --nodegroup-name "${NODEGROUP}" \
        --region "${REGION}" \
        --query 'nodegroup.status' \
        --output text)"

    DESIRED="$(aws eks describe-nodegroup \
        --cluster-name "${CLUSTER}" \
        --nodegroup-name "${NODEGROUP}" \
        --region "${REGION}" \
        --query 'nodegroup.scalingConfig.desiredSize' \
        --output text)"

    echo "Attempt ${i}/30 : status=${STATUS}, desired=${DESIRED}"

    if [[ "${STATUS}" == "ACTIVE" && "${DESIRED}" -ge 2 ]]; then
        break
    fi

    sleep 10

done

FINAL_NODEGROUP_STATUS="$(aws eks describe-nodegroup \
    --cluster-name "${CLUSTER}" \
    --nodegroup-name "${NODEGROUP}" \
    --region "${REGION}" \
    --query 'nodegroup.status' \
    --output text)"

if [[ "${FINAL_NODEGROUP_STATUS}" != "ACTIVE" ]]; then
    echo
    echo "ERROR: Nodegroup did not become ACTIVE."
    exit 1
fi

# ==============================================================
# 5. WAIT FOR SECOND KUBERNETES NODE
# ==============================================================

echo
echo "=============================================================="
echo "5. WAIT FOR SECOND KUBERNETES NODE"
echo "=============================================================="

SECOND_NODE_FOUND="false"

for i in $(seq 1 30); do

    READY_NODES="$(kubectl get nodes \
        --no-headers 2>/dev/null |
        awk '$2=="Ready"{count++} END{print count+0}')"

    TOTAL_NODES="$(kubectl get nodes \
        --no-headers 2>/dev/null |
        wc -l)"

    echo "Attempt ${i}/30 : Ready=${READY_NODES}, Total=${TOTAL_NODES}"

    if [[ "${READY_NODES}" -ge 2 ]]; then
        SECOND_NODE_FOUND="true"
        break
    fi

    sleep 10

done

if [[ "${SECOND_NODE_FOUND}" != "true" ]]; then
    echo
    echo "ERROR: Second Kubernetes node did not become Ready."
    kubectl get nodes -o wide
    exit 1
fi

echo
echo "Two Ready nodes are available."

kubectl get nodes -o wide

# ==============================================================
# 6. CHECK CLOUDWATCH CONTROLLER
# ==============================================================

echo
echo "=============================================================="
echo "6. CLOUDWATCH CONTROLLER STATUS"
echo "=============================================================="

kubectl get pods \
    -n amazon-cloudwatch \
    -o wide

# ==============================================================
# 7. WAIT FOR CLOUDWATCH CONTROLLER
# ==============================================================

echo
echo "=============================================================="
echo "7. WAIT FOR CLOUDWATCH CONTROLLER"
echo "=============================================================="

for i in $(seq 1 30); do

    READY="$(kubectl get deployment \
        amazon-cloudwatch-observability-controller-manager \
        -n amazon-cloudwatch \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"

    READY="${READY:-0}"

    echo "Attempt ${i}/30 : Ready replicas=${READY}"

    if [[ "${READY}" -ge 1 ]]; then
        break
    fi

    sleep 10

done

CONTROLLER_READY="$(kubectl get deployment \
    amazon-cloudwatch-observability-controller-manager \
    -n amazon-cloudwatch \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"

if [[ "${CONTROLLER_READY:-0}" -lt 1 ]]; then

    echo
    echo "ERROR: CloudWatch controller is still not Ready."

    kubectl get pods \
        -n amazon-cloudwatch \
        -o wide

    kubectl get events \
        -n amazon-cloudwatch \
        --sort-by='.lastTimestamp' |
        tail -50

    exit 1
fi

echo
echo "CloudWatch controller is READY."

# ==============================================================
# 8. WAIT FOR CLOUDWATCH ADDON ACTIVE
# ==============================================================

echo
echo "=============================================================="
echo "8. WAIT FOR CLOUDWATCH ADD-ON ACTIVE"
echo "=============================================================="

for i in $(seq 1 30); do

    ADDON_STATUS="$(aws eks describe-addon \
        --cluster-name "${CLUSTER}" \
        --addon-name "${ADDON}" \
        --region "${REGION}" \
        --query 'addon.status' \
        --output text 2>/dev/null || true)"

    echo "Attempt ${i}/30 : ${ADDON_STATUS}"

    if [[ "${ADDON_STATUS}" == "ACTIVE" ]]; then
        break
    fi

    sleep 10

done

FINAL_ADDON_STATUS="$(aws eks describe-addon \
    --cluster-name "${CLUSTER}" \
    --addon-name "${ADDON}" \
    --region "${REGION}" \
    --query 'addon.status' \
    --output text)"

echo
echo "CloudWatch Add-on Status:"
echo "${FINAL_ADDON_STATUS}"

if [[ "${FINAL_ADDON_STATUS}" != "ACTIVE" ]]; then
    echo
    echo "ERROR: CloudWatch add-on is not ACTIVE."

    aws eks describe-addon \
        --cluster-name "${CLUSTER}" \
        --addon-name "${ADDON}" \
        --region "${REGION}" \
        --query 'addon.health' \
        --output json

    exit 1
fi

# ==============================================================
# 9. CLOUDWATCH PODS
# ==============================================================

echo
echo "=============================================================="
echo "9. CLOUDWATCH PODS"
echo "=============================================================="

kubectl get pods \
    -n amazon-cloudwatch \
    -o wide

# ==============================================================
# 10. APPLICATION STATUS
# ==============================================================

echo
echo "=============================================================="
echo "10. APPLICATION STATUS"
echo "=============================================================="

kubectl get deployments \
    -n "${NAMESPACE}"

echo

kubectl get pods \
    -n "${NAMESPACE}" \
    -o wide

echo

kubectl get services \
    -n "${NAMESPACE}"

# ==============================================================
# 11. CLOUDWATCH LOG GROUPS
# ==============================================================

echo
echo "=============================================================="
echo "11. CLOUDWATCH LOG GROUPS"
echo "=============================================================="

echo "Waiting briefly for telemetry..."

sleep 30

aws logs describe-log-groups \
    --region "${REGION}" \
    --log-group-name-prefix "/aws/containerinsights/${CLUSTER}" \
    --query 'logGroups[].{LogGroup:logGroupName,StoredBytes:storedBytes}' \
    --output table || true

# ==============================================================
# 12. CLOUDWATCH ALARM
# ==============================================================

echo
echo "=============================================================="
echo "12. CLOUDWATCH ALARM"
echo "=============================================================="

NODE_NAME="$(kubectl get nodes \
    -o jsonpath='{.items[0].metadata.name}')"

INSTANCE_ID="$(kubectl get node "${NODE_NAME}" \
    -o jsonpath='{.spec.providerID}' |
    awk -F/ '{print $NF}')"

ALARM_NAME="mern-eks-worker-high-cpu"

aws cloudwatch put-metric-alarm \
    --alarm-name "${ALARM_NAME}" \
    --alarm-description "Alarm when EKS worker CPU exceeds 80 percent" \
    --namespace AWS/EC2 \
    --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value="${INSTANCE_ID}" \
    --statistic Average \
    --period 300 \
    --evaluation-periods 2 \
    --threshold 80 \
    --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --region "${REGION}"

echo
aws cloudwatch describe-alarms \
    --alarm-names "${ALARM_NAME}" \
    --region "${REGION}" \
    --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Threshold:Threshold}' \
    --output table

# ==============================================================
# 13. FINAL ADD-ON HEALTH
# ==============================================================

echo
echo "=============================================================="
echo "13. FINAL CLOUDWATCH HEALTH"
echo "=============================================================="

aws eks describe-addon \
    --cluster-name "${CLUSTER}" \
    --addon-name "${ADDON}" \
    --region "${REGION}" \
    --query 'addon.{Status:status,Version:addonVersion,Health:health}' \
    --output json

# ==============================================================
# 14. FINAL REPORT
# ==============================================================

echo
echo "=============================================================="
echo "14. FINAL REPORT"
echo "=============================================================="

{
    echo "=============================================================="
    echo "PHASE 4A - CLOUDWATCH FIX REPORT"
    echo "=============================================================="
    echo
    echo "Date          : $(date)"
    echo "AWS Region    : ${REGION}"
    echo "Cluster       : ${CLUSTER}"
    echo "Nodegroup     : ${NODEGROUP}"
    echo "Node Count    : $(kubectl get nodes --no-headers | wc -l)"
    echo "Ready Nodes   : $(kubectl get nodes --no-headers | awk '$2=="Ready"{count++} END{print count+0}')"
    echo "CloudWatch    : ${FINAL_ADDON_STATUS}"
    echo
    echo "=============================================================="
    echo "NODES"
    echo "=============================================================="
    kubectl get nodes -o wide
    echo
    echo "=============================================================="
    echo "CLOUDWATCH PODS"
    echo "=============================================================="
    kubectl get pods -n amazon-cloudwatch -o wide
    echo
    echo "=============================================================="
    echo "APPLICATION PODS"
    echo "=============================================================="
    kubectl get pods -n "${NAMESPACE}" -o wide
    echo
    echo "=============================================================="
    echo "SERVICES"
    echo "=============================================================="
    kubectl get services -n "${NAMESPACE}"
    echo
    echo "=============================================================="
    echo "CLOUDWATCH LOG GROUPS"
    echo "=============================================================="
    aws logs describe-log-groups \
        --region "${REGION}" \
        --log-group-name-prefix "/aws/containerinsights/${CLUSTER}" \
        --query 'logGroups[].logGroupName' \
        --output table || true
    echo
    echo "=============================================================="
    echo "CLOUDWATCH ALARM"
    echo "=============================================================="
    aws cloudwatch describe-alarms \
        --alarm-names "${ALARM_NAME}" \
        --region "${REGION}" \
        --output table || true
    echo
    echo "=============================================================="
    echo "PHASE 4A SUCCESS"
    echo "=============================================================="
} | tee "${REPORT}"

echo
echo "=============================================================="
echo " PHASE 4A SUCCESSFULLY COMPLETED"
echo "=============================================================="
echo
echo "EKS Nodes:"
kubectl get nodes -o wide

echo
echo "CloudWatch:"
aws eks describe-addon \
    --cluster-name "${CLUSTER}" \
    --addon-name "${ADDON}" \
    --region "${REGION}" \
    --query 'addon.status' \
    --output text

echo
echo "CloudWatch Pods:"
kubectl get pods -n amazon-cloudwatch -o wide

echo
echo "Report:"
echo "${REPORT}"
