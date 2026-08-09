#!/bin/bash

set -u

JENKINS_URL="https://jenkinsacademics.herovired.com"

echo
echo "=============================================================="
echo " JENKINS CAPABILITY CHECK"
echo "=============================================================="

# Prompt securely if token is not already available
if [[ -z "${JENKINS_TOKEN:-}" ]]; then
    read -rsp "Enter Jenkins password/API token: " JENKINS_TOKEN
    echo
fi

AUTH="herovired:${JENKINS_TOKEN}"

echo
echo "1. Authentication"
curl -sS \
    -u "${AUTH}" \
    "${JENKINS_URL}/whoAmI/api/json" |
jq .

echo
echo "2. Jenkins API"
curl -sS \
    -u "${AUTH}" \
    "${JENKINS_URL}/api/json" |
jq '{mode,numExecutors,nodeDescription,quietingDown}'

echo
echo "3. Credentials Store"

curl -sS \
    -u "${AUTH}" \
    "${JENKINS_URL}/credentials/store/system/domain/_/api/json" |
jq '{
    credentialCount: (.credentials | length)
}'

echo
echo "4. Jenkins Jobs"

curl -sS \
    -u "${AUTH}" \
    "${JENKINS_URL}/api/json?tree=jobs[name,url,color]" |
jq '.jobs'

echo
echo "5. CSRF Crumb"

curl -sS \
    -u "${AUTH}" \
    "${JENKINS_URL}/crumbIssuer/api/json" |
jq .

echo
echo "6. Required Jenkins Plugins"

PLUGIN_JSON="$(curl -sS \
    -u "${AUTH}" \
    "${JENKINS_URL}/pluginManager/api/json?depth=1")"

echo "${PLUGIN_JSON}" |
jq -r '
.plugins[] |
select(
    .shortName=="git" or
    .shortName=="workflow-aggregator" or
    .shortName=="pipeline-aws" or
    .shortName=="aws-credentials" or
    .shortName=="credentials-binding"
) |
"\(.shortName)\tversion=\(.version)\tactive=\(.active)\tenabled=\(.enabled)"
'

echo
echo "7. Jenkins Permission / Access Test"

HTTP_CODE="$(curl -sS \
    -o /tmp/jenkins-create-test.out \
    -w '%{http_code}' \
    -u "${AUTH}" \
    -X POST \
    "${JENKINS_URL}/createItem?name=__mern_permission_test__")"

echo "Create-job HTTP status: ${HTTP_CODE}"

if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "201" ]]; then
    echo "CREATE JOB: PERMITTED"

    echo
    echo "Cleaning up permission-test job..."

    curl -sS \
        -u "${AUTH}" \
        -X POST \
        "${JENKINS_URL}/job/__mern_permission_test__/doDelete" \
        -o /dev/null || true

elif [[ "${HTTP_CODE}" == "403" ]]; then
    echo "CREATE JOB: FORBIDDEN"

elif [[ "${HTTP_CODE}" == "401" ]]; then
    echo "CREATE JOB: AUTHENTICATION FAILED"

else
    echo "CREATE JOB: HTTP ${HTTP_CODE}"
fi

echo
echo "=============================================================="
echo " CHECK COMPLETE"
echo "=============================================================="
