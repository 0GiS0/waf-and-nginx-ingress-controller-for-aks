# Variables
RESOURCE_GROUP="waf-and-nginx-ingress-controller"
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

# Create a user identity for the AKS
az identity create --name $AKS_NAME-identity --resource-group $RESOURCE_GROUP

# Get managed identity ID
IDENTITY_RESOURCE_ID=$(az identity show --name $AKS_NAME-identity --resource-group $RESOURCE_GROUP --query id -o tsv)
IDENTITY_CLIENT_ID=$(az identity show --name $AKS_NAME-identity --resource-group $RESOURCE_GROUP --query clientId -o tsv)

# Get VNET id
VNET_ID=$(az network vnet show -g $RESOURCE_GROUP -n $VNET_NAME --query id -o tsv)
SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP -n $AKS_SUBNET --vnet-name $VNET_NAME --query id -o tsv)

#Give AKS permissions to the VNET
az role assignment create --assignee $IDENTITY_CLIENT_ID --scope $VNET_ID --role "Network Contributor"

# Create an AKS
az aks create \
--name $AKS_NAME \
--resource-group $RESOURCE_GROUP \
--node-vm-size Standard_B4ms \
--vnet-subnet-id $SUBNET_ID \
--generate-ssh-keys \
--enable-managed-identity \
--assign-identity $IDENTITY_RESOURCE_ID

# Get credentials
az aks get-credentials -n $AKS_NAME -g $RESOURCE_GROUP

# Install nginx as ingress controller
NAMESPACE=ingress-basic
INTERNAL_LOAD_BALANCER_IP_FOR_NGINX_INGRESS="10.10.0.50"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# https://learn.microsoft.com/en-us/azure/aks/internal-lb
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --create-namespace \
  --namespace $NAMESPACE \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"=true \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-ipv4"=$INTERNAL_LOAD_BALANCER_IP_FOR_NGINX_INGRESS

kubectl get svc -n ingress-basic -w

# Create client environments
kubectl apply -f client-environments/.

# Create probe test
kubectl apply -f health-probe/app-gw-probe.yaml

# Test
kubectl run -it --rm aks-ingress-test --image=mcr.microsoft.com/aks/fundamental/base-ubuntu:v0.0.11 --namespace ingress-basic
apt-get update && apt-get install -y curl
curl -L http://10.10.0.50/check
exit

# Get logs nginx controller
kubectl logs -n ingress-basic -l app.kubernetes.io/name=ingress-nginx --tail 100 -f

#Variables for Application Gateway
APPGW_SUBNET="appgw-subnet"
APPGW_NAME="AppGw"
APPGW_PUBLIC_IP_NAME="AppGwPublicIP"
YOUR_DOMAIN="azuredemo.es"

# Create an appgw subnet
az network vnet subnet create \
-g $RESOURCE_GROUP \
-n $APPGW_SUBNET \
--vnet-name $VNET_NAME \
--address-prefixes 10.20.0.0/16

#Create a standard public IP 
az network public-ip create \
--name $APPGW_PUBLIC_IP_NAME \
--resource-group $RESOURCE_GROUP \
--sku Standard

PUBLIC_IP=$(az network public-ip show --name $APPGW_PUBLIC_IP_NAME --resource-group $RESOURCE_GROUP --query ipAddress -o tsv)

echo "This the public IP you have to configure in your domain: $PUBLIC_IP"

# Create a WAF policy
GENERAL_WAF_POLICY="general-waf-policies"
az network application-gateway waf-policy create \
--name $GENERAL_WAF_POLICY \
--resource-group $RESOURCE_GROUP \
--type OWASP \
--version 3.2

# Create an App Gw with WAF enabled
az network application-gateway create \
-n $APPGW_NAME \
-g $RESOURCE_GROUP \
--sku WAF_v2 \
--public-ip-address $APPGW_PUBLIC_IP_NAME \
--vnet-name $VNET_NAME \
--subnet $APPGW_SUBNET \
--capacity 1 \
--priority 1 \
--waf-policy $GENERAL_WAF_POLICY

# Update default backend pool with the load balancer for nginx ingress
az network application-gateway address-pool update \
--gateway-name $APPGW_NAME \
--resource-group $RESOURCE_GROUP \
--name appGatewayBackendPool \
--servers $INTERNAL_LOAD_BALANCER_IP_FOR_NGINX_INGRESS

# Now update the default listener, using wildcard, that points to the Nginx Controller Ip and routes to the proper web app
# https://learn.microsoft.com/en-us/azure/application-gateway/multiple-site-overview#wildcard-host-names-in-listener-preview (It's not in preview anymore)
# https://azure.microsoft.com/en-us/updates/general-availability-wildcard-listener-on-application-gateways/
az network application-gateway http-listener update \
  --name appGatewayHttpListener \
  --frontend-ip appGatewayFrontendIP \
  --frontend-port appGatewayFrontendPort \
  --resource-group $RESOURCE_GROUP \
  --gateway-name $APPGW_NAME \
  --host-names "*.$YOUR_DOMAIN"

#Update default rule that glues the listener and the backend pool
az network application-gateway rule update \
--gateway-name $APPGW_NAME \
--name "rule1" \
--resource-group $RESOURCE_GROUP \
--http-listener "appGatewayHttpListener" \
--rule-type "Basic" \
--address-pool "appGatewayBackendPool" \
--priority 1

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

# Check domain name
nslookup $YOUR_DOMAIN
dig $YOUR_DOMAIN