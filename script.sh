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
# 5. APLICAR APLICACIONES ARGOCD (GitOps) - SOLO EXTERNAL SECRETS OPERATOR PRIMERO
# --------------------------------------------
echo -e "${BLUE}\n🚀 Desplegando External Secrets Operator...${NC}"
kubectl apply -f argo-apps/external-secrets-app.yaml -n argocd

# --------------------------------------------
# 6. ESPERAR A QUE LOS CRDs DE EXTERNAL SECRETS ESTÉN DISPONIBLES
# --------------------------------------------
echo -e "${BLUE}\n⏳ Esperando que External Secrets Operator instale los CRDs...${NC}"
echo -e "${YELLOW}Esto puede tomar hasta 3 minutos...${NC}"

# Función para verificar si los CRDs están disponibles
check_crds() {
    kubectl get crd clustersecretstores.external-secrets.io > /dev/null 2>&1 && \
    kubectl get crd externalsecrets.external-secrets.io > /dev/null 2>&1
}

# Esperar hasta 3 minutos por los CRDs
TIMEOUT=180
COUNTER=0
while ! check_crds && [ $COUNTER -lt $TIMEOUT ]; do
    echo -e "${YELLOW}⏳ Esperando CRDs... (${COUNTER}/${TIMEOUT}s)${NC}"
    sleep 5
    COUNTER=$((COUNTER + 5))
done

if check_crds; then
    echo -e "${GREEN}✅ CRDs de External Secrets están disponibles${NC}"
else
    echo -e "${RED}❌ Error: CRDs no disponibles después de 3 minutos${NC}"
    echo -e "${YELLOW}Verificando estado de External Secrets Operator...${NC}"
    kubectl get pods -n external-secrets
    exit 1
fi

# --------------------------------------------
# 7. ESPERAR A QUE EL OPERADOR ESTÉ LISTO
# --------------------------------------------
echo -e "${BLUE}\n⏳ Esperando que External Secrets Operator esté listo...${NC}"
kubectl wait --for=condition=available --timeout=180s deployment/external-secrets-operator -n external-secrets

# --------------------------------------------
# 8. AHORA SÍ, APLICAR LA CONFIGURACIÓN DE EXTERNAL SECRETS
# --------------------------------------------
echo -e "${BLUE}\n🔧 Aplicando configuraciones de External Secrets...${NC}"
# La aplicación external-secrets-config ya fue creada, solo necesitamos sincronizarla
kubectl patch application external-secrets-config -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"script"},"sync":{"revision":"HEAD"}}}'

# --------------------------------------------
# 9. APLICAR ATALES-DEV
# --------------------------------------------
echo -e "${YELLOW}📦 Aplicando Atales-Dev...${NC}"
kubectl apply -f argo-apps/atales-dev-app.yaml -n argocd

# --------------------------------------------
# 10. CONFIGURAR PORT-FORWARD
# --------------------------------------------
echo -e "${YELLOW}\n🚪 Habilitando acceso a ArgoCD en https://localhost:8080 ...${NC}"
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
sleep 3

# Mostrar contraseña
echo -e "${GREEN}\n🔑 Contraseña ArgoCD (usuario: admin):${NC}"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# --------------------------------------------
# 11. MONITOREO DE APLICACIONES
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

# Monitorear por 2 minutos
for i in {1..24}; do
    echo -e "\n${BLUE}Estado de aplicaciones (intento $i/24):${NC}"
    check_app_status "external-secrets-operator"
    check_app_status "external-secrets-config" 
    check_app_status "atales-dev"
    
    if [[ $i -lt 24 ]]; then
        sleep 5
    fi
done

# --------------------------------------------
# 12. VERIFICACIÓN FINAL
# --------------------------------------------
echo -e "${BLUE}\n🔍 Verificación final de recursos...${NC}"
echo -e "${YELLOW}External Secrets:${NC}"
kubectl get externalsecrets -n external-secrets 2>/dev/null || echo "  No ExternalSecrets encontrados aún"
echo -e "${YELLOW}ClusterSecretStores:${NC}"
kubectl get clustersecretstores 2>/dev/null || echo "  No ClusterSecretStores encontrados aún"

# --------------------------------------------
# 13. MENSAJE FINAL
# --------------------------------------------
echo -e "${GREEN}\n🚀 GITOPS CONFIGURADO EXITOSAMENTE${NC}"
echo -e "${GREEN}\n💡 Todo está siendo manejado por ArgoCD:${NC}"
echo -e "${YELLOW}👉 External Secrets Operator (Helm Chart)${NC}"
echo -e "${YELLOW}👉 External Secrets Configuraciones${NC}"
echo -e "${YELLOW}👉 Atales-Dev Application${NC}"
echo -e "${YELLOW}👉 UI ArgoCD: https://localhost:8080${NC}"
echo -e "${YELLOW}👉 Usuario: admin | Contraseña: arriba ⬆️${NC}"
echo -e "${GREEN}\n🎯 ¡A partir de ahora, solo necesitás hacer push al repo!${NC}"
