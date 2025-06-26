#!/bin/bash
# 🚀 Script GitOps Puro - Solo infraestructura base
set -e

# 🎨 Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}\n🌐 INICIANDO ENTORNO GITOPS PURO${NC}"

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
# 3. INSTALAR ARGOCD
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
# 4. ESPERAR A QUE ARGOCD ESTÉ LISTO
# --------------------------------------------
echo -e "${BLUE}\n⏳ Esperando que ArgoCD esté listo...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# --------------------------------------------
# 5. APLICAR ATALES-DEV
# --------------------------------------------
echo -e "${YELLOW}📦 Aplicando Atales-Dev...${NC}"
kubectl apply -f argo-apps/atales-dev-app.yaml -n argocd

# --------------------------------------------
# 6. CONFIGURAR PORT-FORWARD
# --------------------------------------------
echo -e "${YELLOW}\n🚪 Habilitando acceso a ArgoCD en https://localhost:8080 ...${NC}"
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
sleep 3

# Mostrar contraseña
echo -e "${GREEN}\n🔑 Contraseña ArgoCD (usuario: admin):${NC}"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# --------------------------------------------
# 7. MONITOREO DE APLICACIONES
# --------------------------------------------
echo -e "${BLUE}\n📊 Monitoreando sincronización de aplicaciones...${NC}"
echo -e "${YELLOW}Esto puede tomar unos minutos...${NC}"

# Función para verificar estado de app
check_app_status() {
    local app_name=$1
    local status=$(kubectl get application $app_name -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "NotFound")
    local health=$(kubectl get application $app_name -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    echo "  $app_name: Sync=$status, Health=$health"
}

# --------------------------------------------
# 13. MENSAJE FINAL
# --------------------------------------------
echo -e "${GREEN}\n🚀 GITOPS CONFIGURADO EXITOSAMENTE${NC}"
echo -e "${GREEN}\n💡 Todo está siendo manejado por ArgoCD:${NC}"
echo -e "${YELLOW}👉 Atales-Dev Application${NC}"
echo -e "${YELLOW}👉 UI ArgoCD: https://localhost:8080${NC}"
echo -e "${YELLOW}👉 Usuario: admin | Contraseña: arriba ⬆️${NC}"
echo -e "${GREEN}\n🎯 ¡A partir de ahora, solo necesitás hacer push al repo!${NC}"
