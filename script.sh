#!/bin/bash
# 🚀 Script GitOps para AWS EKS - Entorno TEST

set -e

# 🎨 Colores para logs bonitos
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}\n🌥️ INICIANDO DESPLIEGUE EN AWS EKS - TEST${NC}"

# --------------------------------------------
# 1. Verificar Conexión con el Cluster EKS
# --------------------------------------------
echo -e "${BLUE}🔍 Verificando acceso a EKS...${NC}"
if ! kubectl cluster-info > /dev/null 2>&1; then
  echo -e "${RED}❌ No se puede acceder al cluster. Verifica tu contexto kubectl.${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Conectado al cluster EKS${NC}"
fi

# --------------------------------------------
# 2. Instalar Sealed Secrets Controller (si no está)
# --------------------------------------------
echo -e "${BLUE}\n🔒 Verificando Sealed Secrets...${NC}"
if ! kubectl get deployment sealed-secrets-controller -n kube-system > /dev/null 2>&1; then
  echo -e "${YELLOW}🟡 Instalando Sealed Secrets Controller...${NC}"
  kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml
  kubectl wait --for=condition=Ready pod -l name=sealed-secrets-controller -n kube-system --timeout=300s
else
  echo -e "${GREEN}✅ Sealed Secrets Controller ya está desplegado${NC}"
fi

# --------------------------------------------
# 3. Crear Namespace TEST (si no existe)
# --------------------------------------------
NAMESPACE="test"
echo -e "${BLUE}📦 Verificando namespace $NAMESPACE...${NC}"
if ! kubectl get namespace $NAMESPACE > /dev/null 2>&1; then
  kubectl create namespace $NAMESPACE
  echo -e "${GREEN}✅ Namespace $NAMESPACE creado${NC}"
else
  echo -e "${GREEN}✅ Namespace $NAMESPACE ya existe${NC}"
fi

# --------------------------------------------
# 4. Aplicar Sealed Secrets
# --------------------------------------------
echo -e "${BLUE}\n🔑 Aplicando Sealed Secrets para $NAMESPACE...${NC}"
kubectl apply -k sealed-secrets/$NAMESPACE/

# --------------------------------------------
# 5. Instalar ArgoCD (si no está)
# --------------------------------------------
echo -e "${BLUE}\n🚀 Verificando ArgoCD...${NC}"
if ! kubectl get ns argocd > /dev/null 2>&1; then
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
  echo -e "${GREEN}✅ ArgoCD instalado${NC}"
else
  echo -e "${GREEN}✅ ArgoCD ya estaba instalado${NC}"
fi

# --------------------------------------------
# 6. Desplegar Aplicaciones
# --------------------------------------------
echo -e "${BLUE}\n🚀 Desplegando aplicaciones en ArgoCD...${NC}"
for app in argo-apps/*; do
  kubectl apply -f "$app" -n argocd
done

# --------------------------------------------
# 7. Acceso a ArgoCD (reemplaza Port Forward por LoadBalancer)
# --------------------------------------------
ARGO_LB=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo -e "${GREEN}\n🔗 Acceso a ArgoCD: https://$ARGO_LB${NC}"

echo -e "${YELLOW}🔑 Usuario: admin${NC}"
echo -e "${YELLOW}🔑 Contraseña:${NC}"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# --------------------------------------------
# 8. Fin del Script
# --------------------------------------------
echo -e "${GREEN}\n🚀 DESPLIEGUE COMPLETO EN EKS - TEST${NC}"

