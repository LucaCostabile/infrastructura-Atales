#!/bin/bash
# 🚀 Script para iniciar Minikube, instalar ArgoCD y desplegar External-Secrets + Atales-Dev
set -e

# 🎨 Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}\n🌐 INICIANDO ENTORNO LOCAL CON MINIKUBE + ARGOCd${NC}"

# --------------------------------------------
# 1. INICIAR MINIKUBE
# --------------------------------------------
echo -e "${BLUE}\n🔍 Verificando Minikube...${NC}"
if ! minikube status > /dev/null 2>&1; then
  echo -e "${YELLOW}🟡 Iniciando Minikube...${NC}"
  minikube start --cpus=3 --memory=4500mb --driver=docker \
    --addons=ingress,metrics-server,dashboard \
    --extra-config=kubelet.housekeeping-interval=10s
else
  echo -e "${GREEN}✅ Minikube ya está corriendo${NC}"
fi

# --------------------------------------------
# 2. CONFIGURAR /etc/hosts
# --------------------------------------------
MINIKUBE_IP=$(minikube ip)
DOMAIN="atales.local"
HOST_ENTRY="$MINIKUBE_IP $DOMAIN"

if ! grep -q "$DOMAIN" /etc/hosts; then
  echo -e "${YELLOW}🔧 Agregando $DOMAIN a /etc/hosts...${NC}"
  echo "$HOST_ENTRY" | sudo tee -a /etc/hosts > /dev/null
else
  echo -e "${GREEN}✅ /etc/hosts ya contiene $DOMAIN${NC}"
fi

# --------------------------------------------
# 3. INSTALAR EXTERNAL SECRETS OPERATOR CON HELM
# --------------------------------------------
echo -e "${BLUE}\n🛠️ Instalando External Secrets Operator...${NC}"

# Verificar si Helm está instalado
if ! command -v helm &> /dev/null; then
    echo -e "${RED}❌ Helm no está instalado. Instalando...${NC}"
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Agregar repo de External Secrets
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Instalar External Secrets Operator
if ! kubectl get ns external-secrets > /dev/null 2>&1; then
    echo -e "${YELLOW}🟡 Instalando External Secrets Operator...${NC}"
    helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
else
    echo -e "${GREEN}✅ External Secrets ya está instalado${NC}"
fi

# Esperar a que ESO esté listo
echo -e "${BLUE}\n⏳ Esperando que External Secrets Operator esté listo...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/external-secrets -n external-secrets

# --------------------------------------------
# 4. INSTALAR ARGOCd (si no está)
# --------------------------------------------
echo -e "${BLUE}\n🛠️ Verificando instalación de ArgoCD...${NC}"
if ! kubectl get ns argocd > /dev/null 2>&1; then
  echo -e "${YELLOW}🟡 Instalando ArgoCD...${NC}"
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
else
  echo -e "${GREEN}✅ ArgoCD ya está instalado${NC}"
fi

# --------------------------------------------
# 5. ESPERAR A QUE ARGOCd ESTÉ LISTO
# --------------------------------------------
echo -e "${BLUE}\n⏳ Esperando que ArgoCD esté listo...${NC}"
while [[ $(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o 'jsonpath={.items[*].status.containerStatuses[*].ready}') != "true" ]]; do
    echo -n "."
    sleep 5
done
echo -e "\n${GREEN}✅ ArgoCD está listo${NC}"

# --------------------------------------------
# 6. APLICAR CONFIGURACIONES DE EXTERNAL SECRETS
# --------------------------------------------
echo -e "${BLUE}\n🔧 Aplicando configuraciones de External Secrets...${NC}"

# Aplicar vault auth secret
kubectl apply -f apps/external-secrets/vault-auth-secret.yaml

# Aplicar cluster secret store
kubectl apply -f apps/external-secrets/clustersecretstore.yaml

# Aplicar external secret
kubectl apply -f apps/external-secrets/backend-external-secret.yaml

# --------------------------------------------
# 7. APLICAR APLICACIÓN ATALES-DEV
# --------------------------------------------
echo -e "${BLUE}\n🚀 Aplicando Atales-Dev App...${NC}"
kubectl apply -f argo-apps/atales-dev-app.yaml -n argocd

# --------------------------------------------
# 8. CONFIGURAR PORT-FORWARD PARA ARGOCd
# --------------------------------------------
echo -e "${YELLOW}\n🚪 Habilitando acceso a la UI de ArgoCD en https://localhost:8080 ...${NC}"
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
sleep 5
echo -e "${GREEN}✅ Port-forward listo${NC}"

# Mostrar contraseña inicial
echo -e "${GREEN}\n🔑 Contraseña inicial de ArgoCD (usuario: admin):${NC}"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# --------------------------------------------
# 9. VERIFICACIÓN FINAL
# --------------------------------------------
echo -e "${BLUE}\n🔍 Verificando instalación...${NC}"
echo -e "${YELLOW}External Secrets Operator:${NC}"
kubectl get pods -n external-secrets

echo -e "${YELLOW}ClusterSecretStore:${NC}"
kubectl get clustersecretstore

echo -e "${YELLOW}External Secrets:${NC}"
kubectl get externalsecret -n external-secrets

# --------------------------------------------
# 10. MENSAJE FINAL
# --------------------------------------------
echo -e "${GREEN}\n🚀 ENTORNO COMPLETAMENTE LEVANTADO CON GITOPS${NC}"
echo -e "${GREEN}\n💡 Pasos siguientes:${NC}"
echo -e "${YELLOW}👉 Entrá a la UI de ArgoCD: https://localhost:8080${NC}"
echo -e "${YELLOW}👉 Usuario: admin${NC}"
echo -e "${YELLOW}👉 Contraseña: (la que te mostré arriba)${NC}"
echo -e "${YELLOW}👉 External Secrets Operator está funcionando${NC}"
echo -e "${YELLOW}👉 No olvides correr: ${BLUE}minikube tunnel${YELLOW} (si usás ingress con LoadBalancer)${NC}"
