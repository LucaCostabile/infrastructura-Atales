#!/bin/bash
# 🚀 Script GitOps Puro - Solo infraestructura base + Sealed Secrets (MEJORADO)
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
# 7. LIMPIAR SECRETS EXISTENTES (IMPORTANTE)
# --------------------------------------------
cleanup_existing_secrets() {
  echo -e "${BLUE}\n🧹 Limpiando secrets existentes que no son manejados por Sealed Secrets...${NC}"
  
  PROBLEMATIC_SECRETS=("backend-secrets" "gateway-secrets" "negocio-secrets" "frontend-secrets")
  
  for env in dev test prod; do
    echo -e "${YELLOW}📁 Limpiando namespace: $env${NC}"
    
    for secret in "${PROBLEMATIC_SECRETS[@]}"; do
      if kubectl get secret $secret -n $env >/dev/null 2>&1; then
        # Verificar si NO está manejado por SealedSecret
        OWNER=$(kubectl get secret $secret -n $env -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || echo "")
        if [ "$OWNER" != "SealedSecret" ]; then
          echo -e "${YELLOW}🗑️  Eliminando secret no manejado: $secret en $env${NC}"
          kubectl delete secret $secret -n $env
        else
          echo -e "${GREEN}✅ Secret $secret ya es manejado por SealedSecret en $env${NC}"
        fi
      fi
    done
  done
}

# --------------------------------------------
# 8. FUNCIÓN PARA GENERAR SEALED SECRETS INICIALES
# --------------------------------------------
generate_initial_sealed_secrets() {
  echo -e "${BLUE}\n🔐 Generando Sealed Secrets iniciales...${NC}"
  
  # Crear directorio para sealed secrets
  mkdir -p sealed-secrets/{dev,test,prod}
  
  for env in dev test prod; do
    echo -e "${YELLOW}📦 Generando sealed secrets para ambiente: $env${NC}"
    
    # 1. Backend secrets
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
    
    # 2. Gateway secrets (ejemplo)
    kubectl create secret generic gateway-secrets \
      --namespace=$env \
      --from-literal=API_KEY="gateway-api-key-$env" \
      --from-literal=SECRET_TOKEN="gateway-secret-$env" \
      --dry-run=client -o yaml | \
    kubeseal --cert sealed-secrets-cert.pem -o yaml > "sealed-secrets/$env/gateway-sealed-secrets.yaml"
    
    # 3. Negocio secrets (ejemplo)
    kubectl create secret generic negocio-secrets \
      --namespace=$env \
      --from-literal=BUSINESS_API_KEY="business-api-key-$env" \
      --from-literal=BUSINESS_SECRET="business-secret-$env" \
      --dry-run=client -o yaml | \
    kubeseal --cert sealed-secrets-cert.pem -o yaml > "sealed-secrets/$env/negocio-sealed-secrets.yaml"
    
    # 4. Frontend TLS secrets (ejemplo)
    kubectl create secret tls frontend-tls \
      --namespace=$env \
      --cert=<(echo "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t") \
      --key=<(echo "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0t") \
      --dry-run=client -o yaml | \
    kubeseal --cert sealed-secrets-cert.pem -o yaml > "sealed-secrets/$env/frontend-sealed-secrets.yaml"
    
    echo -e "${GREEN}✅ Sealed secrets generados para $env${NC}"
  done
}

# --------------------------------------------
# 9. GENERAR KUSTOMIZATION FILES
# --------------------------------------------
generate_kustomization_files() {
  echo -e "${BLUE}\n📄 Generando archivos kustomization.yaml...${NC}"
  
  for env in dev test prod; do
    cat > "sealed-secrets/$env/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - auth-sealed-secrets.yaml
  - gateway-sealed-secrets.yaml
  - negocio-sealed-secrets.yaml
  - frontend-sealed-secrets.yaml

namespace: $env

commonLabels:
  environment: $env
  managed-by: sealed-secrets
EOF
    echo -e "${GREEN}✅ kustomization.yaml generado para $env${NC}"
  done
}

# --------------------------------------------
# 10. GENERAR SEALED SECRETS SI NO EXISTEN
# --------------------------------------------
if [ ! -d "sealed-secrets" ] || [ -z "$(ls -A sealed-secrets 2>/dev/null)" ]; then
  cleanup_existing_secrets
  generate_initial_sealed_secrets
  generate_kustomization_files
else
  echo -e "${GREEN}✅ Sealed secrets ya existen${NC}"
  cleanup_existing_secrets
fi

# --------------------------------------------
# 11. APLICAR SEALED SECRETS CON KUSTOMIZE
# --------------------------------------------
echo -e "${BLUE}\n🚀 Aplicando Sealed Secrets...${NC}"

for env in dev test prod; do
  if [ -f "sealed-secrets/$env/kustomization.yaml" ]; then
    echo -e "${YELLOW}📦 Aplicando sealed secrets para $env con Kustomize...${NC}"
    kubectl apply -k sealed-secrets/$env/
  else
    echo -e "${YELLOW}📦 Aplicando sealed secrets para $env directamente...${NC}"
    kubectl apply -f sealed-secrets/$env/ 2>/dev/null || true
  fi
done

# --------------------------------------------
# 12. VERIFICAR QUE LOS SECRETS FUERON CREADOS
# --------------------------------------------
echo -e "${BLUE}\n🔍 Verificando que los secrets fueron creados correctamente:${NC}"
sleep 10

EXPECTED_SECRETS=("backend-secrets" "gateway-secrets" "negocio-secrets" "frontend-tls")

for env in dev test prod; do
  echo -e "\n${YELLOW}--- Namespace: $env ---${NC}"
  for secret in "${EXPECTED_SECRETS[@]}"; do
    if kubectl get secret $secret -n $env >/dev/null 2>&1; then
      # Verificar que fue creado por SealedSecret
      OWNER=$(kubectl get secret $secret -n $env -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || echo "")
      if [ "$OWNER" = "SealedSecret" ]; then
        echo -e "${GREEN}✅ $secret - Creado por SealedSecret${NC}"
      else
        echo -e "${YELLOW}⚠️  $secret - Existe pero no es manejado por SealedSecret${NC}"
      fi
    else
      echo -e "${RED}❌ $secret - No encontrado${NC}"
    fi
  done
done

# --------------------------------------------
# 13. INSTALAR ARGOCD
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
# 14. ESPERAR A QUE ARGOCD ESTÉ LISTO
# --------------------------------------------
echo -e "${BLUE}\n⏳ Esperando que ArgoCD esté listo...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# --------------------------------------------
# 15. APLICAR ATALES-DEV (solo si existe)
# --------------------------------------------
if [ -f "argo-apps/atales-dev-app.yaml" ]; then
  echo -e "${YELLOW}📦 Aplicando Atales-Dev...${NC}"
  kubectl apply -f argo-apps/atales-dev-app.yaml -n argocd
else
  echo -e "${YELLOW}⚠️  Archivo argo-apps/atales-dev-app.yaml no encontrado, saltando...${NC}"
fi

# --------------------------------------------
# 16. CONFIGURAR PORT-FORWARD
# --------------------------------------------
echo -e "${YELLOW}\n🚪 Habilitando acceso a ArgoCD en https://localhost:8080 ...${NC}"

# Matar procesos port-forward existentes
pkill -f "kubectl port-forward.*argocd-server" 2>/dev/null || true
sleep 2

kubectl port-forward svc/argocd-server -n argocd 8080:443 > /dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 3

# Mostrar contraseña
echo -e "${GREEN}\n🔑 Contraseña ArgoCD (usuario: admin):${NC}"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# --------------------------------------------
# 17. CREAR BACKUP DE LA CLAVE PRIVADA
# --------------------------------------------
echo -e "${BLUE}\n💾 Creando backup de la clave privada de Sealed Secrets...${NC}"
kubectl get secret -n kube-system sealed-secrets-key -o yaml > sealed-secrets-private-key-backup.yaml
echo -e "${GREEN}✅ Backup guardado en sealed-secrets-private-key-backup.yaml${NC}"

# --------------------------------------------
# 18. MONITOREO DE APLICACIONES
# --------------------------------------------
echo -e "${BLUE}\n📊 Monitoreando sincronización de aplicaciones...${NC}"

# Función para verificar estado de app
check_app_status() {
    local app_name=$1
    local status=$(kubectl get application $app_name -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "NotFound")
    local health=$(kubectl get application $app_name -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    echo "  $app_name: Sync=$status, Health=$health"
}

# Verificar aplicaciones si existen
if kubectl get applications -n argocd >/dev/null 2>&1; then
  echo -e "${YELLOW}Estado de aplicaciones ArgoCD:${NC}"
  kubectl get applications -n argocd --no-headers | while read app rest; do
    check_app_status $app
  done
else
  echo -e "${YELLOW}No hay aplicaciones ArgoCD desplegadas aún${NC}"
fi

# --------------------------------------------
# 19. MENSAJE FINAL
# --------------------------------------------
echo -e "${GREEN}\n🚀 GITOPS + SEALED SECRETS CONFIGURADO EXITOSAMENTE${NC}"
echo -e "${GREEN}\n💡 Resumen de lo configurado:${NC}"
echo -e "${YELLOW}✅ Minikube iniciado y configurado${NC}"
echo -e "${YELLOW}✅ Sealed Secrets Controller instalado${NC}"
echo -e "${YELLOW}✅ Namespaces creados: dev, test, prod${NC}"
echo -e "${YELLOW}✅ Sealed Secrets generados y aplicados${NC}"
echo -e "${YELLOW}✅ ArgoCD instalado y funcionando${NC}"

echo -e "${GREEN}\n🔗 Accesos:${NC}"
echo -e "${YELLOW}👉 ArgoCD UI: https://localhost:8080${NC}"
echo -e "${YELLOW}👉 Usuario: admin | Contraseña: mostrada arriba ⬆️${NC}"
echo -e "${YELLOW}👉 Minikube Dashboard: minikube dashboard${NC}"

echo -e "${GREEN}\n🔒 Archivos importantes:${NC}"
echo -e "${YELLOW}📁 sealed-secrets/*/  - Archivos Sealed Secrets (COMMITEAR)${NC}"
echo -e "${YELLOW}🔑 sealed-secrets-cert.pem - Clave pública (NO commitear)${NC}"
echo -e "${YELLOW}💾 sealed-secrets-private-key-backup.yaml - Backup clave privada (GUARDAR SEGURO)${NC}"

echo -e "${GREEN}\n🎯 Próximos pasos:${NC}"
echo -e "${YELLOW}1. Actualizar los valores en los sealed secrets con datos reales${NC}"
echo -e "${YELLOW}2. Commitear los archivos sealed-secrets/* al repositorio${NC}"
echo -e "${YELLOW}3. Configurar las aplicaciones ArgoCD${NC}"
echo -e "${YELLOW}4. ¡Hacer push y ver la magia del GitOps!${NC}"

echo -e "${GREEN}\n🔄 Port-forward activo con PID: $PORT_FORWARD_PID${NC}"
echo -e "${YELLOW}Para detenerlo: kill $PORT_FORWARD_PID${NC}"