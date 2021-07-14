#!/bin/bash
# shellcheck disable=SC2059,SC2016,SC2181

# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# <http://www.apache.org/licenses/LICENSE-2.0>
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

# options
pps=""
while(($#)); do
case "$1" in
  -o|--org)
    APIGEE_ORG="$2"
    shift 2;;  
    
  -e|--env)
    APIGEE_ENV="$2"
    shift 2;;     

  -t|--token)
    TOKEN="$2"
    shift 2;;

  -t|--token)
    TOKEN="$2"
    shift 2;;     

  -h|--hostname)
    HOSTNAME="$2"
    shift 2;;      

  *)
    pps="$pps $1"
    shift;;
esac
done
eval set -- "$pps"

#Check Parameters

if [ -z "$APIGEE_ORG" ]; then
   >&2 echo "ERROR: Environment variable APIGEE_ORG is not set."
   >&2 echo "       export APIGEE_ORG=<your-apigee-org-name>"
   exit 1
fi

if [ -z "$APIGEE_ENV" ]; then
   >&2 echo "ERROR: Environment variable APIGEE_ENV is not set."
   >&2 echo "       export APIGEE_ENV=<your-apigee-env-name>"
   exit 1
fi

if [ -z "$TOKEN" ]; then
   >&2 echo "ERROR: Environment variable TOKEN is not set."
   >&2 echo "       export TOKEN=\$(gcloud auth print-access-token)"
   exit 1
fi

if [ -z "$HOSTNAME" ]; then
   >&2 echo "ERROR: Environment variable HOSTNAME is not set."
   >&2 echo "       export HOST=<your-juiceshop-target-host>"
   exit 1
fi

PROXY_NAME=OWASP-Juiceshop
APIPRODUCT_NAME=$PROXY_NAME-Product
APP_NAME=$PROXY_NAME-App

# Step 1: Configure target server
echo "Configuring the target server in the $APIGEE_ENV environment"
curl -X POST -H "Content-type:application/json" -H "Authorization: Bearer $TOKEN" \
"https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/environments/$APIGEE_ENV/targetservers" \
-d "{\"name\": \"TS-Juiceshop\",\"host\": \"$HOSTNAME\",\"isEnabled\": true,\"port\": 443,\"sSLInfo\": {\"enabled\": \"true\"}}"
echo "Targetserver TS-Juiceshop configured successfully" 

# Step 2: Import and deploy Apigee proxy bundle
echo "Importing the $PROXY_NAME bundle to the $APIGEE_ENV environment"
PROXY_REVISION=$(curl -X POST -H "Content-type:multipart/form-data" -H "Authorization: Bearer $TOKEN" \
"https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/apis?name=$PROXY_NAME&action=import&validate=true" \
-F "file=@OWASP-JuiceShop.zip" | jq -r '.revision')
echo "Revision of the proxy imported: $PROXY_REVISION"

echo "Deploying proxy revision: $PROXY_REVISION"
curl -X POST -H "Content-type:application/json" -H "Authorization: Bearer $TOKEN" \
"https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/environments/$APIGEE_ENV/apis/$PROXY_NAME/revisions/$PROXY_REVISION/deployments?override=true" \
-d ""

echo "Proxy deployed successfully" 

# Step 3: Configure API Product
echo "Configuring the API Product in the $APIGEE_ORG org"
curl -X POST -H "Content-type:application/json" -H "Authorization: Bearer $TOKEN" \
"https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/apiproducts" \
-d "{\"name\": \"$APIPRODUCT_NAME\",\"displayName\": \"$APIPRODUCT_NAME\",\"description\": \"$APIPRODUCT_NAME\",\"apiResources\": [\"/**\",\"/\"],\"approvalType\": \"auto\",\"attributes\": [],\"environments\": [\"$APIGEE_ENV\"],\"proxies\": [\"$PROXY_NAME\"]}"
echo "API Product configured successfully" 

# Step 4: Configure Developer
echo "Configuring the Developer in the $APIGEE_ORG org"
curl -X POST -H "Content-type:application/json" -H "Authorization: Bearer $TOKEN" \
"https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/developers" \
-d "{\"email\": \"developer@juiceshop.com\",\"firstName\": \"Juiceshop\",\"lastName\": \"Developer\",\"userName\": \"developer\"}"
echo "Developer configured successfully" 

# Step 5: Configure Dev App
echo "Configuring the Dev app in the $APIGEE_ORG org"
API_KEY=$(curl -X POST -H "Content-type:application/json" -H "Authorization: Bearer $TOKEN" \
"https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/developers/developer@juiceshop.com/apps" \
-d "{\"apiProducts\": [\"$APIPRODUCT_NAME\"],\"callbackUrl\": \"\",\"name\": \"$APP_NAME\",\"scopes\": []}" | jq -r '.credentials[0].consumerKey')
echo "Dev App configured successfully" 
echo "API Key: $API_KEY"

echo "Apigee setup is complete"
