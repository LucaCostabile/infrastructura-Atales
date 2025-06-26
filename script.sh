#!/bin/bash
# 🚀 Script GitOps Puro - Solo infraestructura base + Sealed Secrets
set -e

# 🎨 Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}\n🌐 INICIANDO ENTORNO GITOPS PURO + SEALED SECRETS${NC}"

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
# 3. INSTALAR SEALED SECRETS CONTROLLER
# --------------------------------------------
echo -e "${BLUE}\n🔒 Verificando instalación de Sealed Secrets...${NC}"
if ! kubectl get deployment sealed-secrets-controller -n kube-system > /dev/null 2>&1; then
  echo -e "${YELLOW}🟡 Instalando Sealed Secrets Controller...${NC}"
  kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.18.0/controller.yaml
  
  echo -e "${BLUE}⏳ Esperando que Sealed Secrets esté listo...${NC}"
  kubectl wait --for=condition=Ready pod -l name=sealed-secrets-controller -n kube-system --timeout=300s
else
  echo -e "${GREEN}✅ Sealed Secrets Controller ya está instalado${NC}"
fi

# --------------------------------------------
# 4. INSTALAR KUBESEAL CLI
# --------------------------------------------
echo -e "${BLUE}\n🛠️ Verificando kubeseal CLI...${NC}"
if ! command -v kubeseal &> /dev/null; then
  echo -e "${YELLOW}🟡 Instalando kubeseal CLI...${NC}"
  KUBESEAL_VERSION="0.18.0"
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  
  # Mapear arquitectura
  case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l) ARCH="arm" ;;
  esac
  
  wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-${OS}-${ARCH}.tar.gz"
  tar -xvzf "kubeseal-${KUBESEAL_VERSION}-${OS}-${ARCH}.tar.gz"
  sudo install -m 755 kubeseal /usr/local/bin/kubeseal
  rm -f "kubeseal-${KUBESEAL_VERSION}-${OS}-${ARCH}.tar.gz" kubeseal
  
  echo -e "${GREEN}✅ kubeseal CLI instalado${NC}"
else
  echo -e "${GREEN}✅ kubeseal CLI ya está instalado${NC}"
fi

# --------------------------------------------
# 5. CREAR NAMESPACES NECESARIOS
# --------------------------------------------
echo -e "${BLUE}\n📁 Creando Namespaces...${NC}"
for ns in dev test prod; do
  if ! kubectl get namespace $ns > /dev/null 2>&1; then
    kubectl create namespace $ns
    echo -e "${GREEN}✅ Namespace $ns creado${NC}"
  else
    echo -e "${GREEN}✅ Namespace $ns ya existe${NC}"
  fi
done

# --------------------------------------------
# 6. OBTENER CLAVE PÚBLICA PARA SEALED SECRETS
# --------------------------------------------
echo -e "${BLUE}\n🔑 Obteniendo clave pública del cluster...${NC}"
kubeseal --fetch-cert > sealed-secrets-cert.pem
echo -e "${GREEN}✅ Clave pública guardada en sealed-secrets-cert.pem${NC}"

# --------------------------------------------
# 7. FUNCIÓN PARA GENERAR SEALED SECRETS INICIALES
# --------------------------------------------
generate_initial_sealed_secrets() {
  echo -e "${BLUE}\n🔐 Generando Sealed Secrets iniciales...${NC}"
  
  # Crear directorio para sealed secrets
  mkdir -p sealed-secrets/{dev,test,prod}
  
  for env in dev test prod; do
    echo -e "${YELLOW}📦 Generando sealed secret para ambiente: $env${NC}"
    
    # Generar sealed secret con valores de ejemplo (cambiar por valores reales)
    kubectl create secret generic backend-secrets \
      --namespace=$env \
      --from-literal=CRYPTO_SECRET="example-crypto-secret-$env" \
      --from-literal=DB_PASSWORD="example-db-password-$env" \
      --from-literal=DB_USER="atales_user" \
      --from-literal=EXTERNAL_API_KEY="example-api-key-$env" \
      --from-literal=GMAIL_APP_PASSWORD="example-gmail-password-$env" \
      --from-literal=GMAIL_USER="atales@example.com" \
      --from-literal=JWT_SECRET_KEY="example-jwt-secret-$env" \
      --dry-run=client -o yaml | \
    kubeseal --cert sealed-secrets-cert.pem -o yaml > "sealed-secrets/$env/auth-sealed-secrets.yaml"
    
    echo -e "${GREEN}✅ Sealed secret generado para $env${NC}"
  done
}

# --------------------------------------------
# 8. GENERAR SEALED SECRETS INICIALES
# --------------------------------------------
if [ ! -d "sealed-secrets" ] || [ -z "$(ls -A sealed-secrets 2>/dev/null)" ]; then
  generate_initial_sealed_secrets
else
  echo -e "${GREEN}✅ Sealed secrets ya existen${NC}"
fi

# --------------------------------------------
# 9. APLICAR SEALED SECRETS
# --------------------------------------------
echo -e "${BLUE}\n🚀 Aplicando Sealed Secrets...${NC}"
kubectl apply -f sealed-secrets/ --recursive

# Verificar que los secrets fueron creados
echo -e "${BLUE}\n🔍 Verificando secrets creados...${NC}"
for env in dev test prod; do
  if kubectl get secret backend-secrets -n $env > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Secret backend-secrets creado en namespace $env${NC}"
  else
    echo -e "${RED}❌ Error: Secret backend-secrets NO encontrado en namespace $env${NC}"
  fi
done

# --------------------------------------------
# 10. INSTALAR ARGOCD
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
# 11. ESPERAR A QUE ARGOCD ESTÉ LISTO
# --------------------------------------------
echo -e "${BLUE}\n⏳ Esperando que ArgoCD esté listo...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# --------------------------------------------
# 12. APLICAR ATALES-DEV
# --------------------------------------------
echo -e "${YELLOW}📦 Aplicando Atales-Dev...${NC}"
kubectl apply -f argo-apps/atales-dev-app.yaml -n argocd

# --------------------------------------------
# 13. CONFIGURAR PORT-FORWARD
# --------------------------------------------
echo -e "${YELLOW}\n🚪 Habilitando acceso a ArgoCD en https://localhost:8080 ...${NC}"
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
sleep 3

# Mostrar contraseña
echo -e "${GREEN}\n🔑 Contraseña ArgoCD (usuario: admin):${NC}"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# --------------------------------------------
# 14. CREAR BACKUP DE LA CLAVE PRIVADA
# --------------------------------------------
echo -e "${BLUE}\n💾 Creando backup de la clave privada de Sealed Secrets...${NC}"
kubectl get secret -n kube-system sealed-secrets-key -o yaml > sealed-secrets-private-key-backup.yaml
echo -e "${GREEN}✅ Backup guardado en sealed-secrets-private-key-backup.yaml${NC}"

# --------------------------------------------
# 15. MONITOREO DE APLICACIONES
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
# 16. MENSAJE FINAL
# --------------------------------------------
echo -e "${GREEN}\n🚀 GITOPS + SEALED SECRETS CONFIGURADO EXITOSAMENTE${NC}"
echo -e "${GREEN}\n💡 Todo está siendo manejado por ArgoCD:${NC}"
echo -e "${YELLOW}👉 Atales-Dev Application${NC}"
echo -e "${YELLOW}👉 UI ArgoCD: https://localhost:8080${NC}"
echo -e "${YELLOW}👉 Usuario: admin | Contraseña: arriba ⬆️${NC}"
echo -e "${GREEN}\n🔒 Sealed Secrets configurado:${NC}"
echo -e "${YELLOW}📁 sealed-secrets/*/auth-sealed-secrets.yaml - Archivos cifrados (commitear)${NC}"
echo -e "${YELLOW}🔑 sealed-secrets-cert.pem - Clave pública (NO commitear)${NC}"
echo -e "${YELLOW}💾 sealed-secrets-private-key-backup.yaml - Backup clave privada (GUARDAR SEGURO)${NC}"
echo -e "${GREEN}\n🎯 ¡A partir de ahora, solo necesitás hacer push al repo!${NC}"
echo -e "${GREEN}🔄 Los secrets se actualizan automáticamente desde el pipeline${NC}"