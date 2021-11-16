# Variables
RESOURCE_GROUP="waf-and-nginx-ingress"
LOCATION="northeurope"
AKS_NAME="aks-with-nginx-ingress"
VNET_NAME="aks-vnet"
AKS_SUBNET="aks-subnet"

# Create a resource group
az group create -n $RESOURCE_GROUP -l $LOCATION

# Create a VNET and aks subnet
az network vnet create -g $RESOURCE_GROUP -n $VNET_NAME \
--address-prefixes 10.0.0.0/8 \
--subnet-name $AKS_SUBNET \
--subnet-prefix 10.10.0.0/16

#Create service principal for aks
az ad sp create-for-rbac --skip-assignment > auth.json

#Get the service principal ID
APP_ID=$(jq -r '.appId' auth.json)
#Get the service principal password
PASSWORD=$(jq -r '.password' auth.json)

# Get VNET id
VNET_ID=$(az network vnet show -g $RESOURCE_GROUP -n $VNET_NAME --query id -o tsv)
SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP -n $AKS_SUBNET --vnet-name $VNET_NAME --query id -o tsv)

#Give AKS permissions to the VNET
az role assignment create --assignee $APP_ID --scope $VNET_ID --role "Network Contributor"

# Create an AKS
az aks create -n $AKS_NAME -g $RESOURCE_GROUP \
--vnet-subnet-id $SUBNET_ID \
--service-principal $APP_ID \
--client-secret $PASSWORD \
--generate-ssh-keys \
--node-count 1

# Get credentials
az aks get-credentials -n $AKS_NAME -g $RESOURCE_GROUP

# Install nginx
NAMESPACE="ingress-basic"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx --create-namespace --namespace $NAMESPACE -f internal-ingress.yaml

kubectl get svc -n ingress-basic

# Create client environments
kubectl apply -f client-environments/.

# Create probe test
kubectl apply -f health-probe/app-gw-probe.yaml

# Test
kubectl run -it --rm aks-ingress-test --image=mcr.microsoft.com/aks/fundamental/base-ubuntu:v0.0.11 --namespace ingress-basic
apt-get update && apt-get install -y curl
curl -L http://10.10.0.50/check
exit

#Variables for Application Gateway
APPGW_SUBNET="appgw-subnet"
APPGW_NAME="AppGw"
APPGW_PUBLIC_IP_NAME="AppGwPublicIP"
INTERNAL_LOAD_BALANCER_IP_FOR_NGINX_INGRESS="10.10.0.50"
YOUR_DOMAIN="azuredemo.es"

# Create an appgw subnet
az network vnet subnet create -g $RESOURCE_GROUP -n $APPGW_SUBNET \
--vnet-name $VNET_NAME \
--address-prefixes 10.20.0.0/16

#Create a standard public IP 
az network public-ip create --name $APPGW_PUBLIC_IP_NAME --resource-group $RESOURCE_GROUP --sku Standard
PUBLIC_IP=$(az network public-ip show --name $APPGW_PUBLIC_IP_NAME --resource-group $RESOURCE_GROUP --query ipAddress -o tsv)

echo "This the public IP you have to configure in your domain: $PUBLIC_IP"

# Create an App Gw with WAF enabled
az network application-gateway create -n $APPGW_NAME -g $RESOURCE_GROUP \
--sku WAF_v2 --public-ip-address $APPGW_PUBLIC_IP_NAME \
--vnet-name $VNET_NAME \
--subnet $APPGW_SUBNET

# Add backend pool with the load balancer for nginx ingress
az network application-gateway address-pool create \
--gateway-name $APPGW_NAME \
--resource-group $RESOURCE_GROUP \
--name nginx-controller-pool \
--servers $INTERNAL_LOAD_BALANCER_IP_FOR_NGINX_INGRESS

# Now add listener, using wildcard, that points to the Nginx Controller Ip and routes to the proper web app
az network application-gateway http-listener create \
  --name aks-ingress-listener \
  --frontend-ip appGatewayFrontendIP \
  --frontend-port appGatewayFrontendPort \
  --resource-group $RESOURCE_GROUP \
  --gateway-name $APPGW_NAME \
  --host-names "*.$YOUR_DOMAIN"

#Add a rule that glues the listener and the backend pool
az network application-gateway rule create \
  --gateway-name $APPGW_NAME \
  --name aks-apps \
  --resource-group $RESOURCE_GROUP \
  --http-listener aks-ingress-listener \
  --rule-type Basic \
  --address-pool nginx-controller-pool

#Create health probe
az network application-gateway probe create \
--gateway-name $APPGW_NAME \
--resource-group $RESOURCE_GROUP \
--name "probe-azuredemo-es" \
--host $INTERNAL_LOAD_BALANCER_IP_FOR_NGINX_INGRESS \
--path "/check" \
--protocol "Http"

#Add HTTP settings a custom probe
az network application-gateway http-settings update \
--gateway-name $APPGW_NAME \
--name "appGatewayBackendHttpSettings" \
--resource-group $RESOURCE_GROUP \
--probe "probe-azuredemo-es"

#See all ingress configured
kubectl get ingress --all-namespaces
