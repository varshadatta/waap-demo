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
  -p|--project)
    PROJECT_ID="$2"
    shift 2;;

  -c|--certificates)
    CERTIFICATES="$2"
    shift 2;;
    
  -o|--org)
    APIGEE_ORG="$2"
    shift 2;;  

  -e|--env)
    APIGEE_ENV="$2"
    shift 2;;    
    
    
  -z|--zone)
    ZONE="$2"
    shift 2;;      
    
    
  -a|--api_endpoint)
    API_ENDPOINT="$2"
    shift 2;; 
    
  -b|--basepath)
    BASEPATH="$2"
    shift 2;;   

  *)
    pps="$pps $1"
    shift;;
esac
done
eval set -- "$pps"


#Check dependencies

#for dependency in jq openssl
#do
#  if ! [ -x "$(command -v $dependency)" ]; then
#    >&2 echo "ABORTED: Required command is not on your PATH: $dependency."
#    >&2 echo "         Please install it before you continue."
#    exit 2
#  fi
#done


#Check Parameters

if [ -z "$PROJECT_ID" ]; then
   >&2 echo "ERROR: Environment variable PROJECT_ID is not set."
   >&2 echo "       export PROJECT_ID=<your-gcp-project-name>"
   exit 1
fi

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

if [ -z "$ZONE" ]; then
   >&2 echo "ERROR: Environment variable ZONE is not set."
   >&2 echo "       export ZONE=<your-zone-name>"
   exit 1
fi

if [ -z "$API_ENDPOINT" ]; then
   >&2 echo "ERROR: Environment variable API_ENDPOINT is not set."
   >&2 echo "       export API_ENDPOINT=<your-apigee-endpoint>"
   exit 1
fi

if [ -z "$BASEPATH" ]; then
   >&2 echo "ERROR: Environment variable BASEPATH is not set."
   >&2 echo "       export BASEPATH=<your-apigee-basepath>"
   exit 1
fi


# Step 1: Define functions and environment variables
function token { echo -n "$(gcloud config config-helper --force-auth-refresh | grep access_token | grep -o -E '[^ ]+$')" ; }

export ORG=$APIGEE_ORG

echo "CHECK: Checking if organization $ORG is already provisioned"
ORG_JSON=$(curl --silent -H "Authorization: Bearer $(token)"  -X GET -H "Content-Type:application/json" https://apigee.googleapis.com/v1/organizations/"$ORG")

APIGEE_PROVISIONED="F"
if [ "ACTIVE" = "$(echo "$ORG_JSON" | jq --raw-output .state)" ]; then
  APIGEE_PROVISIONED="T"
  echo "Apigee Organization exists and is active"

else
  >&2 echo "ERROR: Didn't find an active Apigee Organization."
  >&2 echo "       Please configure your Apigee instance and then rerun this script."
  exit 1
  
fi

export CERTIFICATES=${CERTIFICATES:-managed}
CERT_DISPLAY=$CERTIFICATES

if [ "$CERTIFICATES" = "provided" ];then
  if [ -f "$RUNTIME_TLS_KEY" ] && [ -f "$RUNTIME_TLS_CERT" ]; then
    CERT_DISPLAY="$CERT_DISPLAY key: $RUNTIME_TLS_KEY, cert $RUNTIME_TLS_CERT"
  else
    echo "you selected CERTIFICATES=$CERTIFICATES but RUNTIME_TLS_KEY and/or RUNTIME_TLS_CERT is missing"
    exit 1
  fi
fi

echo ""
echo "Resolved Configuration: "
echo "  PROJECT=$PROJECT_ID"
echo "  APIGEE ORG=$APIGEE_ORG"
echo "  APIGEE ENV=$APIGEE_ENV"
echo "  ZONE=$ZONE"
echo "  CERTIFICATES=$CERTIFICATES"
echo "  API_ENDPOINT=$API_ENDPOINT"
echo "  BASEPATH=$BASEPATH"
echo ""


echo "Step 1: Enable APIs"
gcloud services enable apigee.googleapis.com cloudbuild.googleapis.com compute.googleapis.com cloudresourcemanager.googleapis.com servicenetworking.googleapis.com cloudkms.googleapis.com --project="$PROJECT_ID" --quiet

echo "Step 2: Upload Apigee Proxy, create API Product and get App Key"

echo "Step 2.1: Uploading Proxy Bundle"

#Check if proxy bundle already exists and import if not
echo "Step 2.1.1: Check if proxy already exists"
PROXY_JSON=$(curl --silent -H "Authorization: Bearer $(token)"  -X GET -H "Content-Type:application/json" "https://apigee.googleapis.com/v1/organizations/$ORG/apis/waap-demo-proxy")

if [ "Proxy" = "$(echo "$PROXY_JSON" | jq --raw-output .metaData.subType)" ]; then

  echo "Proxy bundle is already deployed, skipping import."

else
  echo "Proxy bundle is not deployed, importing proxy."
  echo "Step 2.1.2: Importing proxy bundle"
  IMPORT_JSON=$(curl --silent -H "Authorization: Bearer $(token)" \
    -X POST "https://apigee.googleapis.com/v1/organizations/$ORG/apis?name=waap-demo-proxy&action=import" \
    --form file='@waap-demo-proxy-bundle.zip' \
    -H "Content-Type: multipart/form-data")

  echo $IMPORT_JSON  

  echo "Step 2.1.3 Deploying API Proxy"
  DEPLOY_JSON=$(curl --silent -H "Authorization: Bearer $(token)" \
    -X POST "https://apigee.googleapis.com/v1/organizations/$ORG/environments/$APIGEE_ENV/apis/waap-demo-proxy/revisions/1/deployments" )

  echo $DEPLOY_JSON
fi


#Check if API Product already exists and create if not
echo "Step 2.3.1: Check if API Product already exists"
PRODUCT_JSON=$(curl --silent -H "Authorization: Bearer $(token)"  \
  -X GET -H "Content-Type:application/json" \
  "https://apigee.googleapis.com/v1/organizations/$ORG/apiproducts/waap-demo-product")

if [ "waap-demo-product" = "$(echo "$PRODUCT_JSON" | jq --raw-output .name)" ]; then

  echo "Product is already deployed, skipping creation."

else
  echo "Product is not deployed, creating product."
  echo "Step 2.2.2: Creating product"
  IMPORT_PRODUCT_JSON=$(curl --silent -H "Authorization: Bearer $(token)" \
    -X POST "https://apigee.googleapis.com/v1/organizations/$ORG/apiproducts" \
    -H "Content-Type: application/json" \
    --data '{ "name":"waap-demo-product", "proxies":["waap-demo-proxy"], "displayName":"Waap Demo Product", "environments":["'"$APIGEE_ENV"'"], "description":"Waap Demo Product", "approvalType":"auto"}')

  echo $IMPORT_PRODUCT_JSON  
fi

#Check if Developer already exists and create if not
echo "Step 2.3.1: Check if Developer already exists"
DEVELOPER_JSON=$(curl --silent -H "Authorization: Bearer $(token)"  \
  -X GET -H "Content-Type:application/json" \
  "https://apigee.googleapis.com/v1/organizations/$ORG/developers/waapdemo@google.com")

if [ "waapdemo@google.com" = "$(echo "$DEVELOPER_JSON" | jq --raw-output .email)" ]; then

  echo "Developer is already created, skipping creation."

else
  echo "Developer is not created, creating developer."
  echo "Step 2.3.2: Creating Developer app"
  IMPORT_DEV_JSON=$(curl --silent -H "Authorization: Bearer $(token)" \
    -X POST "https://apigee.googleapis.com/v1/organizations/$ORG/developers" \
    -H "Content-Type: application/json" \
    --data '{ "email":"waapdemo@google.com", "firstName":"WaaP", "lastName":"Demo", "userName":"WaapDemo"}')

  echo $IMPORT_DEV_JSON  
fi

#Check if Developer app already exists and create if not
echo "Step 2.4.1: Check if Developer App already exists"
APP_JSON=$(curl --silent -H "Authorization: Bearer $(token)"  \
  -X GET -H "Content-Type:application/json" \
  "https://apigee.googleapis.com/v1/organizations/$ORG/apps?expand=true")

echo $APP_JSON

if [ "waap-demo-app" = "$(echo "$APP_JSON" | jq --raw-output '.app[] | select (.name=="waap-demo-app") | .name')"  ]; then

  echo "Developer App is already deployed, skipping creation."
  export APIKEY=$(echo "$APP_JSON" | jq --raw-output '.app[] | select (.name=="waap-demo-app") | .credentials[].consumerKey')

else
  echo "Developer App is not deployed, creating App."
  echo "Step 2.4.2: Creating Developer app"
  IMPORT_APP_JSON=$(curl --silent -H "Authorization: Bearer $(token)" \
    -X POST "https://apigee.googleapis.com/v1/organizations/$ORG/developers/waapdemo@google.com/apps/" \
    -H "Content-Type: application/json" \
    --data '{ "name":"waap-demo-app", "apiProducts":["waap-demo-product"]}')

  echo $IMPORT_APP_JSON  

  export APIKEY=$(echo "$IMPORT_APP_JSON" | jq --raw-output '.credentials[].consumerKey')

fi

echo APIKEY is $APIKEY

echo "Step 3: Create gcr image"
echo "Step 3.1: Build and submit Juice chop image"

export IMAGETAG=gcr.io/$PROJECT_ID/owasp-juice-shop
gcloud builds submit --project=$PROJECT_ID --config=cloudbuild.yaml \
  --substitutions=_API_ENDPOINT=$API_ENDPOINT,_BASEPATH=$BASEPATH,_APIKEY=$APIKEY,_IMAGETAG=$IMAGETAG .

echo "Step 4: Create Juice shop MIG"
#create image template
echo "Step 4.1: Create Image Template"
gcloud beta compute --project=$PROJECT_ID instance-templates create-with-container juiceshop-demo-template \
    --machine-type=n2-standard-2 \
    --network=projects/$PROJECT_ID/global/networks/default \
    --network-tier=PREMIUM --metadata=google-logging-enabled=true,google-monitoring-enabled=true \
    --maintenance-policy=MIGRATE \
    --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append \
    --tags=juiceshop,http-server,https-server \
    --image-project=cos-cloud \
    --boot-disk-size=10GB \
    --boot-disk-type=pd-balanced \
    --boot-disk-device-name=juiceshop-demo-template \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --container-image=$IMAGETAG \
    --container-restart-policy=always 


#Create managed instance group & health check
echo "Step 4.2: Create managed instance group"
gcloud compute --project $PROJECT_ID health-checks create http juiceshop-healthcheck \
    --timeout "5" \
    --check-interval "10" \
    --unhealthy-threshold "3" \
    --healthy-threshold "2" \
    --port "3000" \
    --request-path "/rest/admin/application-version"

echo "Step 4.3: Create healthcheck"
gcloud beta compute --project=$PROJECT_ID instance-groups managed create juiceshop-demo-mig \
    --base-instance-name=juiceshop-demo-mig \
    --template=juiceshop-demo-template \
    --size=1 \
    --zone=$ZONE \
    --health-check=juiceshop-healthcheck \
    --initial-delay=300

echo "Step 4.4: Set autoscaling"
gcloud beta compute --project $PROJECT_ID instance-groups managed set-autoscaling juiceshop-demo-mig \
    --zone $ZONE \
    --cool-down-period "60" \
    --max-num-replicas "2" \
    --min-num-replicas "1" \
    --target-cpu-utilization "0.6" \
    --mode "on"    


echo "Step 5: Set up networking and certificates"

#Create backend group 
echo "Step 5.1: Create backend"
gcloud compute backend-services create juiceshop-be \
    --project "$PROJECT_ID" \
    --protocol=HTTP \
    --port-name=http-juiceshop \
    --health-checks=juiceshop-healthcheck

echo "Step 5.2: Add backend to instance group"
gcloud compute backend-services add-backend juiceshop-be \
    --project "$PROJECT_ID" \
    --instance-group=juiceshop-demo-mig \
    --instance-group-zone=$ZONE 

#Create URL map 
echo "Step 5.3: Create URL Map"
gcloud compute url-maps create web-map-https \
    --project "$PROJECT_ID" \
    --default-service juiceshop-be


echo "Step 5.4.1: Reserve an IP address for the Load Balancer"
gcloud compute addresses create lb-ipv4-vip-1 \
    --project "$PROJECT_ID" \
    --ip-version=IPV4 \
    --global \
    --project "$PROJECT_ID" \
    --quiet

echo "Step 5.4.2: Get a reserved IP address"
RUNTIME_IP=$(gcloud compute addresses describe lb-ipv4-vip-1 --format="get(address)" --global --project "$PROJECT_ID" --quiet)
export RUNTIME_IP
echo RUNTIME_IP is $RUNTIME_IP
RUNTIME_HOST_ALIAS=$(echo "$RUNTIME_IP" | tr '.' '-').nip.io
export RUNTIME_HOST_ALIAS
echo RUNTIME_HOST_ALIAS is $RUNTIME_HOST_ALIAS


#grab / generate certificates
if [ "$CERTIFICATES" = "managed" ]; then
  echo "Step 5.4.3: Using Google managed certificate:"
  
  gcloud compute ssl-certificates create juiceshop-ssl-cert \
    --domains="$RUNTIME_HOST_ALIAS" --project "$PROJECT_ID" --quiet
    
elif [ "$CERTIFICATES" = "generated" ]; then
  echo "Step 5.4.4: Generate eval certificate and key"
  export RUNTIME_TLS_CERT=~/mig-cert.pem
  export RUNTIME_TLS_KEY=~/mig-key.pem
  openssl req -x509 -out "$RUNTIME_TLS_CERT" -keyout "$RUNTIME_TLS_KEY" -newkey rsa:2048 -nodes -sha256 -subj '/CN='"$RUNTIME_HOST_ALIAS"'' -extensions EXT -config <( printf "[dn]\nCN=$RUNTIME_HOST_ALIAS\n[req]\ndistinguished_name=dn\n[EXT]\nbasicConstraints=critical,CA:TRUE,pathlen:1\nsubjectAltName=DNS:$RUNTIME_HOST_ALIAS\nkeyUsage=digitalSignature,keyCertSign\nextendedKeyUsage=serverAuth")

  echo "Step 5.4.5: Upload your TLS server certificate and key to GCP"
  gcloud compute ssl-certificates create juiceshop-ssl-cert \
    --certificate="$RUNTIME_TLS_CERT" \
    --private-key="$RUNTIME_TLS_KEY" --project "$PROJECT_ID" --quiet
else
  echo "Step 5.4.6: Upload your TLS server certificate and key to GCP"
  gcloud compute ssl-certificates create juiceshop-ssl-cert \
    --certificate="$RUNTIME_TLS_CERT" \
    --private-key="$RUNTIME_TLS_KEY" --project "$PROJECT_ID" --quiet
fi


#Create a proxy rule 
echo "Step 5.5: Create a Proxy rule"
gcloud compute target-https-proxies create https-lb-proxy \
    --project "$PROJECT_ID" \
    --url-map web-map-https \
    --ssl-certificates juiceshop-ssl-cert


#Create a forwarding rule 
echo "Step 5.6: Create a forwarding rule"
gcloud compute forwarding-rules create https-content-rule \
    --project "$PROJECT_ID" \
    --address=lb-ipv4-vip-1 \
    --global \
    --target-https-proxy=https-lb-proxy \
    --ports=443


echo "Step 6: Set up firewall rules"

echo "Step 6.1: Allow all egress"
gcloud compute firewall-rules create "allow-all-egress-juiceshop-https" \
    --project "$PROJECT_ID" \
    --allow=tcp:443 \
    --direction=EGRESS \
    --target-tags=juiceshop \
    --priority=1000

echo "Step 6.2: Allow lb healtcheck"
gcloud compute firewall-rules create "allow-lb-health-check" \
    --project "$PROJECT_ID" \
    --allow=tcp:80,tcp:443,tcp:3000 \
    --source-ranges="130.211.0.0/22,35.191.0.0/16" \
    --direction=INGRESS \
    --target-tags=juiceshop \
    --priority=1000

echo "Step 6.3: Allow HTTP traffic"
gcloud compute firewall-rules create "default-allow-http" \
    --project "$PROJECT_ID" \
    --allow=tcp:80 \
    --source-ranges="0.0.0.0/0" \
    --direction=INGRESS \
    --target-tags=http-server \
    --priority=1000

echo "Step 6.4: Allow HTTPS traffic"
gcloud compute firewall-rules create "default-allow-https" \
    --project "$PROJECT_ID" \
    --allow=tcp:443 \
    --source-ranges="0.0.0.0/0" \
    --direction=INGRESS \
    --target-tags=https-server \
    --priority=1000

echo "Step 6.5: Allow port 3000"
gcloud compute firewall-rules create "default-allow-http-3000" \
    --project "$PROJECT_ID" \
    --allow=tcp:3000 \
    --source-ranges="0.0.0.0/0" \
    --direction=INGRESS \
    --priority=1000


echo "Step 7: Set up Cloud Armor"
gcloud compute --project="$PROJECT_ID" security-policies create waap-demo-juice-shop

gcloud compute --project="$PROJECT_ID" security-policies rules create 3000 --action=deny-403 --security-policy=waap-demo-juice-shop --description="block xss" --expression=evaluatePreconfiguredExpr\(\'xss-stable\',\ \[\'owasp-crs-v030001-id941110-xss\',\ \'owasp-crs-v030001-id941120-xss\',\ \'owasp-crs-v030001-id941130-xss\',\ \'owasp-crs-v030001-id941140-xss\',\ \'owasp-crs-v030001-id941160-xss\',\ \'owasp-crs-v030001-id941170-xss\',\ \'owasp-crs-v030001-id941180-xss\',\ \'owasp-crs-v030001-id941190-xss\',\ \'owasp-crs-v030001-id941200-xss\',\ \'owasp-crs-v030001-id941210-xss\',\ \'owasp-crs-v030001-id941220-xss\',\ \'owasp-crs-v030001-id941230-xss\',\ \'owasp-crs-v030001-id941240-xss\',\ \'owasp-crs-v030001-id941250-xss\',\ \'owasp-crs-v030001-id941260-xss\',\ \'owasp-crs-v030001-id941270-xss\',\ \'owasp-crs-v030001-id941280-xss\',\ \'owasp-crs-v030001-id941290-xss\',\ \'owasp-crs-v030001-id941300-xss\',\ \'owasp-crs-v030001-id941310-xss\',\ \'owasp-crs-v030001-id941350-xss\',\ \'owasp-crs-v030001-id941150-xss\',\ \'owasp-crs-v030001-id941320-xss\',\ \'owasp-crs-v030001-id941330-xss\',\ \'owasp-crs-v030001-id941340-xss\'\]\)

gcloud compute --project="$PROJECT_ID" security-policies rules create 7000 --action=deny-403 --security-policy=waap-demo-juice-shop --description=Block\ US\ IP\ \&\ header:\ Hacker --expression=origin.region_code\ ==\ \'US\'\ \&\&\ request.headers\[\'user-agent\'\].contains\(\'Hacker\'\)

gcloud compute --project="$PROJECT_ID" security-policies rules create 7001 --action=deny-403 --security-policy=waap-demo-juice-shop --description="Regular Expression Rule" --expression=request.headers\[\'user-agent\'\].contains\(\'Hacker\'\)

gcloud compute --project="$PROJECT_ID" security-policies rules create 9000 --action=deny-403 --security-policy=waap-demo-juice-shop --description="block sql injection" --expression=evaluatePreconfiguredExpr\(\'sqli-stable\',\ \[\'owasp-crs-v030001-id942251-sqli\',\ \'owasp-crs-v030001-id942420-sqli\',\ \'owasp-crs-v030001-id942431-sqli\',\ \'owasp-crs-v030001-id942460-sqli\',\ \'owasp-crs-v030001-id942421-sqli\',\ \'owasp-crs-v030001-id942432-sqli\'\]\)

#gcloud compute --project="$PROJECT_ID" security-policies rules create 9997 --action=deny-403 --security-policy=waap-demo-juice-shop --description="Deny all requests below 0.8 reCAPTCHA score" --expression=recaptchaTokenScore\(\)\ \<=\ 0.9

gcloud compute --project="$PROJECT_ID" security-policies rules create 2147483646 --action=allow --security-policy=waap-demo-juice-shop --description="Default rule, higher priority overrides it" --src-ip-ranges=\*

#gcloud compute --project="$PROJECT_ID" backend-services update https-lb-proxy --security-policy=waap-demo-juice-shop

gcloud compute --project="$PROJECT_ID" backend-services update juiceshop-be --security-policy=waap-demo-juice-shop



echo "BUILD COMPLETE"
