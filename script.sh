#!/bin/bash
# 🚀 Script GitOps - Solo infraestructura base
set -e

# 🎨 Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}\n🌐 INICIANDO ENTORNO GITOPS CON MINIKUBE + ARGOCd${NC}"

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
# 3. INSTALAR ARGOCd
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
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# --------------------------------------------
# 5. APLICAR APLICACIONES ARGOCD (GitOps)
# --------------------------------------------
echo -e "${BLUE}\n🚀 Aplicando aplicaciones ArgoCD...${NC}"

# Aplicar External Secrets (con Helm)
kubectl apply -f argo-apps/external-secrets-app.yaml -n argocd

# Aplicar Atales-Dev
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
# 7. MENSAJE FINAL
# --------------------------------------------
echo -e "${GREEN}\n🚀 GITOPS CONFIGURADO EXITOSAMENTE${NC}"
echo -e "${GREEN}\n💡 ArgoCD está sincronizando automáticamente:${NC}"
echo -e "${YELLOW}👉 External Secrets Operator + Configuraciones${NC}"
echo -e "${YELLOW}👉 Atales-Dev Application${NC}"
echo -e "${YELLOW}👉 UI ArgoCD: https://localhost:8080${NC}"
echo -e "${YELLOW}👉 Usuario: admin | Contraseña: arriba ⬆️${NC}"
