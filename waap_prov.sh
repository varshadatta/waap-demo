
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
    
    
  -z|--zone)
    ZONE="$2"
    shift 2;;      
    
    
  -e|--api_endpoint)
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
echo "  ZONE=$ZONE"
echo "  CERTIFICATES=$CERTIFICATES"
echo "  API_ENDPOINT=$API_ENDPOINT"
echo "  BASEPATH=$BASEPATH"
echo ""


echo "Step 1: Enable APIs"
#TODO: update this permissions list
gcloud services enable apigee.googleapis.com cloudbuild.googleapis.com compute.googleapis.com cloudresourcemanager.googleapis.com servicenetworking.googleapis.com cloudkms.googleapis.com --project="$PROJECT_ID" --quiet

echo "Step 2: Upload Apigee Proxy, create API Product and get App Key"
#TODO 
#IVAN this just needs to read the APIKEY env variable, not set it
export APP_KEY=4K79ZECuIAJigebR1bBBTkNNRTcXLjzRq8G4cDVB46RhXXJN 


echo "Step 3: Create gcr image"
echo "Step 3.1: Clone juice shop repo"
#git clone https://github.com/varshadatta/waap-demo
#TODO - either sed replace the envs variable or use a version where we parameterise the inputs
cd waap-demo
docker build --build-arg API_ENDPOINT=$API_ENDPOINT --build-arg APIKEY=$APIKEY . -t varshadatta/waap-demo
export IMAGETAG=gcr.io/$PROJECT_ID/owasp-juice-shop
echo "Step 3.3: Submit image build"

gcloud builds submit --project=$PROJECT_ID \
    --tag $IMAGETAG \
    --timeout="1h"

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
#TODO


echo "Test Instructions"
#TODO
