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
# 3. INSTALAR ARGOCd (si no está)
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
# 4. ESPERAR A QUE ARGOCd ESTÉ LISTO
# --------------------------------------------
echo -e "${BLUE}\n⏳ Esperando que ArgoCD esté listo...${NC}"

while [[ $(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o 'jsonpath={.items[*].status.containerStatuses[*].ready}') != "true" ]]; do
    echo -n "."
    sleep 5
done

echo -e "\n${GREEN}✅ ArgoCD está listo${NC}"

# --------------------------------------------
# 5. APLICAR LAS 2 APLICACIONES (external-secrets y atales-dev)
# --------------------------------------------
echo -e "${BLUE}\n🚀 Aplicando External-Secrets App...${NC}"
kubectl apply -f argo-apps/external-secrets-app.yaml -n argocd

echo -e "${BLUE}\n🚀 Aplicando Atales-Dev App...${NC}"
kubectl apply -f argo-apps/atales-dev-app.yaml -n argocd

# --------------------------------------------
# 6. CONFIGURAR PORT-FORWARD PARA ARGOCd
# --------------------------------------------
echo -e "${YELLOW}\n🚪 Habilitando acceso a la UI de ArgoCD en https://localhost:8080 ...${NC}"
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

sleep 5
echo -e "${GREEN}✅ Port-forward listo${NC}"

# Mostrar contraseña inicial
echo -e "${GREEN}\n🔑 Contraseña inicial de ArgoCD (usuario: admin):${NC}"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# --------------------------------------------
# 7. MENSAJE FINAL
# --------------------------------------------
echo -e "${GREEN}\n🚀 ENTORNO COMPLETAMENTE LEVANTADO CON GITOPS${NC}"
echo -e "${GREEN}\n💡 Pasos siguientes:${NC}"
echo -e "${YELLOW}👉 Entrá a la UI de ArgoCD: https://localhost:8080${NC}"
echo -e "${YELLOW}👉 Usuario: admin${NC}"
echo -e "${YELLOW}👉 Contraseña: (la que te mostré arriba)${NC}"
echo -e "${YELLOW}👉 ArgoCD está desplegando automáticamente External Secrets y Atales-Dev${NC}"
echo -e "${YELLOW}👉 No olvides correr: ${BLUE}minikube tunnel${YELLOW} (si usás ingress con LoadBalancer)${NC}"

