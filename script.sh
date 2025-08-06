#!/bin/bash
# 🚀 Script GitOps Actualizado - Solo usa Secrets de DEV
set -e

# 🎨 Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}\n🌐 INICIANDO ENTORNO GITOPS MULTI-APP + SEALED SECRETS (SOLO DEV)${NC}"

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
# 3. INSTALAR SEALED SECRETS CONTROLLER (MODIFICADO)
# --------------------------------------------
echo -e "${BLUE}\n🔒 Verificando instalación de Sealed Secrets...${NC}"

# PRIMERO: Verificar si existe backup de clave privada
if [ -f "sealed-secrets-private-key-backup.yaml" ]; then
  echo -e "${YELLOW}🔄 Restaurando clave privada desde backup...${NC}"
  
# Eliminar instalación existente si hay
  kubectl delete -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml --ignore-not-found > /dev/null 2>&1 || true
  
 echo -e "${YELLOW}🗑️  Eliminando secret existente de Sealed Secrets...${NC}"
SECRET_NAME=$(grep 'name:' sealed-secrets-private-key-backup.yaml | head -n1 | awk '{print $2}')
kubectl delete secret "$SECRET_NAME" -n kube-system --ignore-not-found

echo -e "${YELLOW}♻️ Aplicando backup de clave privada...${NC}"
kubectl apply -f sealed-secrets-private-key-backup.yaml -n kube-system

  if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Error al aplicar backup de clave privada${NC}"
    exit 1
  fi

  echo -e "${YELLOW}🟡 Instalando Sealed Secrets Controller con clave restaurada...${NC}"
  kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml
  if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Error al instalar el Sealed Secrets Controller${NC}"
    exit 1
  fi

  echo -e "${BLUE}⏳ Esperando que Sealed Secrets esté listo tras restaurar clave...${NC}"
  kubectl wait --for=condition=Ready pod -l name=sealed-secrets-controller -n kube-system --timeout=300s || {
    echo -e "${RED}❌ El controlador no quedó listo tras la restauración${NC}"
    echo -e "${YELLOW}📝 Mostrando logs del pod...${NC}"
    kubectl logs -n kube-system -l name=sealed-secrets-controller --tail=50
    exit 1
  }
  sleep 10

  
  echo -e "${GREEN}✅ Clave privada restaurada desde backup${NC}"
else
  # Flujo normal si no hay backup
  if ! kubectl get deployment sealed-secrets-controller -n kube-system > /dev/null 2>&1; then
    echo -e "${YELLOW}🟡 Instalando Sealed Secrets Controller...${NC}"
    kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml
  else
    echo -e "${GREEN}✅ Sealed Secrets Controller ya está instalado${NC}"
  fi
fi

echo -e "${BLUE}⏳ Esperando que Sealed Secrets esté listo...${NC}"
kubectl wait --for=condition=Ready pod -l name=sealed-secrets-controller -n kube-system --timeout=300s > /dev/null 2>&1
sleep 10

# --------------------------------------------
# 4. INSTALAR KUBESEAL CLI
# --------------------------------------------
echo -e "${BLUE}\n🛠️ Verificando kubeseal CLI...${NC}"
if ! command -v kubeseal &> /dev/null; then
  echo -e "${YELLOW}🟡 Instalando kubeseal CLI...${NC}"
  KUBESEAL_VERSION="0.24.0"
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  
  case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l) ARCH="arm" ;;
  esac
  
  wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-${OS}-${ARCH}.tar.gz" > /dev/null 2>&1
  tar -xvzf "kubeseal-${KUBESEAL_VERSION}-${OS}-${ARCH}.tar.gz" > /dev/null 2>&1
  sudo install -m 755 kubeseal /usr/local/bin/kubeseal > /dev/null 2>&1
  rm -f "kubeseal-${KUBESEAL_VERSION}-${OS}-${ARCH}.tar.gz" kubeseal > /dev/null 2>&1
  echo -e "${GREEN}✅ kubeseal CLI instalado${NC}"
else
  echo -e "${GREEN}✅ kubeseal CLI ya está instalado${NC}"
fi

# --------------------------------------------
# 5. CREAR NAMESPACE DEV
# --------------------------------------------
echo -e "${BLUE}\n📁 Verificando namespace dev...${NC}"
if ! kubectl get namespace dev > /dev/null 2>&1; then
  kubectl create namespace dev
  echo -e "${GREEN}✅ Namespace dev creado${NC}"
else
  echo -e "${GREEN}✅ Namespace dev ya existe${NC}"
fi

# --------------------------------------------
# 6. VERIFICAR Y OBTENER CLAVE PÚBLICA
# --------------------------------------------
echo -e "${BLUE}\n🔑 Verificando controlador Sealed Secrets...${NC}"

wait_for_sealed_secrets_controller() {
  local max_attempts=12
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    if kubeseal --fetch-cert > /dev/null 2>&1; then
      echo -e "${GREEN}✅ Controlador listo${NC}"
      return 0
    fi
    
    echo -e "${YELLOW}🔄 Intento $attempt/$max_attempts - Esperando 15 segundos...${NC}"
    sleep 15
    attempt=$((attempt + 1))
  done
  
  echo -e "${RED}❌ Error: Controlador no responde${NC}"
  kubectl get deployment sealed-secrets-controller -n kube-system || true
  kubectl get pods -n kube-system -l name=sealed-secrets-controller || true
  kubectl logs -n kube-system -l name=sealed-secrets-controller --tail=20 || true
  return 1
}

if ! wait_for_sealed_secrets_controller; then
  exit 1
fi

echo -e "${BLUE}\n🔑 Obteniendo clave pública...${NC}"
kubeseal --fetch-cert > sealed-secrets-cert.pem
echo -e "${GREEN}✅ Clave pública guardada${NC}"

# --------------------------------------------
# 7. LIMPIAR SECRETS EXISTENTES EN DEV
# --------------------------------------------
cleanup_existing_secrets() {
  echo -e "${BLUE}\n🧹 Limpiando secrets existentes en dev...${NC}"
  
  PROBLEMATIC_SECRETS=("backend-secrets" "gateway-secrets" "negocio-secrets" "frontend-tls")
  
  for secret in "${PROBLEMATIC_SECRETS[@]}"; do
    if kubectl get secret $secret -n dev >/dev/null 2>&1; then
      OWNER=$(kubectl get secret $secret -n dev -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || echo "")
      if [ "$OWNER" != "SealedSecret" ]; then
        echo -e "${YELLOW}🗑️  Eliminando secret no manejado: $secret${NC}"
        kubectl delete secret $secret -n dev
      else
        echo -e "${GREEN}✅ $secret manejado por SealedSecret${NC}"
      fi
    fi
  done
}

# --------------------------------------------
# 8. VERIFICAR SECRETS EXISTENTES SOLO EN DEV
# --------------------------------------------
verify_existing_secrets() {
  echo -e "${BLUE}\n🔍 Verificando archivos Sealed Secrets en dev...${NC}"
  
  REQUIRED_SECRETS=(
    "auth-sealed-secrets.yaml"
    "frontend-sealed-secrets.yaml"
    "gateway-sealed-secrets.yaml"
    "negocio-sealed-secrets.yaml"
  )
  
  missing_secrets=0
  
  for secret_file in "${REQUIRED_SECRETS[@]}"; do
    if [ ! -f "sealed-secrets/dev/$secret_file" ]; then
      echo -e "${RED}❌ Falta archivo: sealed-secrets/dev/$secret_file${NC}"
      missing_secrets=$((missing_secrets + 1))
    else
      echo -e "${GREEN}✅ Archivo presente: $secret_file${NC}"
    fi
  done
  
  if [ $missing_secrets -gt 0 ]; then
    echo -e "${RED}🚨 Error: Faltan $missing_secrets archivos de secrets para dev${NC}"
    echo -e "${YELLOW}Por favor, crea los archivos necesarios en sealed-secrets/dev/ antes de continuar${NC}"
    exit 1
  fi
}

# --------------------------------------------
# 9. GENERAR KUSTOMIZATION FILE PARA DEV
# --------------------------------------------
generate_kustomization_file() {
  echo -e "${BLUE}\n📄 Generando kustomization.yaml para dev...${NC}"
  
  cat > "sealed-secrets/dev/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - auth-sealed-secrets.yaml
  - gateway-sealed-secrets.yaml
  - negocio-sealed-secrets.yaml
  - frontend-sealed-secrets.yaml

namespace: dev

commonLabels:
  environment: dev
  managed-by: sealed-secrets
EOF
  echo -e "${GREEN}✅ kustomization.yaml para dev creado${NC}"
}

# --------------------------------------------
# 10. APLICAR SEALED SECRETS SOLO EN DEV
# --------------------------------------------
apply_dev_secrets() {
  echo -e "${BLUE}\n🚀 Aplicando Sealed Secrets en dev...${NC}"
  
  verify_existing_secrets
  cleanup_existing_secrets
  generate_kustomization_file
  
  echo -e "${YELLOW}📦 Aplicando secrets para dev...${NC}"
  kubectl apply -k sealed-secrets/dev/
}

apply_dev_secrets

# --------------------------------------------
# 11. VERIFICAR SECRETS EN CLUSTER (SOLO DEV)
# --------------------------------------------
echo -e "${BLUE}\n🔍 Verificando secrets en dev...${NC}"
sleep 10

EXPECTED_SECRETS=("backend-secrets" "gateway-secrets" "negocio-secrets" "frontend-tls")

echo -e "\n${YELLOW}--- Namespace: dev ---${NC}"
for secret in "${EXPECTED_SECRETS[@]}"; do
  if kubectl get secret $secret -n dev >/dev/null 2>&1; then
    OWNER=$(kubectl get secret $secret -n dev -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || echo "")
    if [ "$OWNER" = "SealedSecret" ]; then
      echo -e "${GREEN}✅ $secret - OK${NC}"
    else
      echo -e "${YELLOW}⚠️  $secret - No manejado por SealedSecret${NC}"
    fi
  else
    echo -e "${RED}❌ $secret - No encontrado${NC}"
  fi
done

# --------------------------------------------
# 12. INSTALAR ARGOCD
# --------------------------------------------
echo -e "${BLUE}\n🛠️ Instalando ArgoCD...${NC}"
if ! kubectl get ns argocd > /dev/null 2>&1; then
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
else
  echo -e "${GREEN}✅ ArgoCD ya está instalado${NC}"
fi

echo -e "${BLUE}\n⏳ Esperando que ArgoCD esté listo...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd > /dev/null 2>&1

# --------------------------------------------
# 13. ELIMINAR APLICACIÓN ANTIGUA
# --------------------------------------------
echo -e "${BLUE}\n🗑️  Limpiando aplicación antigua...${NC}"
if kubectl get application atales-dev -n argocd > /dev/null 2>&1; then
  kubectl delete application atales-dev -n argocd
  echo -e "${GREEN}✅ Aplicación antigua eliminada${NC}"
else
  echo -e "${GREEN}✅ No hay aplicación antigua que eliminar${NC}"
fi

# --------------------------------------------
# 14. APLICAR NUEVAS APLICACIONES ARGO CD
# --------------------------------------------
echo -e "${BLUE}\n🚀 Desplegando nuevas aplicaciones Argo CD...${NC}"

APPS=(
  "mysql-app.yaml"
  "frontend-app.yaml"
  "api-gateway-app.yaml"
  "business-service-app.yaml"
  "auth-service-app.yaml"
)

for app in "${APPS[@]}"; do
  if [ -f "argo-apps/${app}" ]; then
    echo -e "${YELLOW}📦 Aplicando ${app}...${NC}"
    kubectl apply -f "argo-apps/${app}" -n argocd
    sleep 2
  else
    echo -e "${RED}❌ Archivo argo-apps/${app} no encontrado${NC}"
  fi
done

# --------------------------------------------
# 15. CONFIGURAR PORT-FORWARD
# --------------------------------------------
echo -e "${YELLOW}\n🚪 Habilitando acceso a ArgoCD...${NC}"
pkill -f "kubectl port-forward.*argocd-server" 2>/dev/null || true
sleep 2

kubectl port-forward svc/argocd-server -n argocd 8080:443 > /dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 3

echo -e "${GREEN}\n🔑 Contraseña ArgoCD (admin):${NC}"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# --------------------------------------------
# 16. BACKUP CLAVE PRIVADA (MODIFICADO)
# --------------------------------------------
create_sealed_secrets_backup() {
  echo -e "${BLUE}\n💾 Creando backup de clave privada...${NC}"
  
  # Solo crear backup si no existe uno previo
  if [ ! -f "sealed-secrets-private-key-backup.yaml" ]; then
    POSSIBLE_SECRET_NAMES=(
      "sealed-secrets-key"
      "sealed-secrets-controller"
      "sealed-secrets-tls"
    )
    
    SECRET_FOUND=false
    
    for secret_name in "${POSSIBLE_SECRET_NAMES[@]}"; do
      if kubectl get secret "$secret_name" -n kube-system >/dev/null 2>&1; then
        kubectl get secret "$secret_name" -n kube-system -o yaml > "sealed-secrets-private-key-backup.yaml"
        echo -e "${GREEN}✅ Backup guardado${NC}"
        SECRET_FOUND=true
        break
      fi
    done
    
    if [ "$SECRET_FOUND" = false ]; then
      SEALED_SECRETS=$(kubectl get secrets -n kube-system --no-headers | grep -i sealed | awk '{print $1}' || true)
      
      if [ -n "$SEALED_SECRETS" ]; then
        FIRST_SECRET=$(echo "$SEALED_SECRETS" | head -n1)
        kubectl get secret "$FIRST_SECRET" -n kube-system -o yaml > "sealed-secrets-private-key-backup.yaml"
        echo -e "${GREEN}✅ Backup guardado (secret alternativo)${NC}"
      else
        echo -e "${RED}❌ No se encontró el secret${NC}"
        cat > sealed-secrets-debug.txt << EOF
# Debug info
$(date)

## Deployment:
$(kubectl get deployment sealed-secrets-controller -n kube-system -o wide 2>&1)

## Pods:
$(kubectl get pods -n kube-system -l name=sealed-secrets-controller -o wide 2>&1)

## Logs:
$(kubectl logs -n kube-system -l name=sealed-secrets-controller --tail=50 2>&1)

## Secrets:
$(kubectl get secrets -n kube-system 2>&1)
EOF
        echo -e "${YELLOW}📝 Debug info en sealed-secrets-debug.txt${NC}"
      fi
    fi
  else
    echo -e "${YELLOW}✅ Backup ya existe, omitiendo creación${NC}"
  fi
}

create_sealed_secrets_backup

# --------------------------------------------
# 17. VERIFICAR ESTADO APLICACIONES
# --------------------------------------------
echo -e "${BLUE}\n📊 Verificando estado de aplicaciones...${NC}"
sleep 15

check_app_status() {
    local app_name=$1
    local status=$(kubectl get application $app_name -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "NotFound")
    local health=$(kubectl get application $app_name -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    echo -n -e "${YELLOW}${app_name}:${NC} "
    [ "$status" = "Synced" ] && echo -n -e "${GREEN}Sync=${status}${NC}, " || echo -n -e "${RED}Sync=${status}${NC}, "
    [ "$health" = "Healthy" ] && echo -e "${GREEN}Health=${health}${NC}" || echo -e "${RED}Health=${health}${NC}"
    
    if [ "$status" != "Synced" ] || [ "$health" != "Healthy" ]; then
      kubectl get application $app_name -n argocd -o jsonpath='{.status.conditions}' | jq -r '.[] | select(.type == "ComparisonError" or .type == "ReconciliationError") | .message'
    fi
}

for app in "${APPS[@]}"; do
  app_name=$(basename "$app" .yaml)
  if kubectl get application "$app_name" -n argocd >/dev/null 2>&1; then
    check_app_status "$app_name"
  else
    echo -e "${RED}❌ $app_name no encontrada${NC}"
  fi
done

# --------------------------------------------
# 18. MENSAJE FINAL
# --------------------------------------------
echo -e "${GREEN}\n🚀 CONFIGURACIÓN COMPLETADA (SOLO DEV)${NC}"
echo -e "${GREEN}\n💡 Resumen:${NC}"
echo -e "${YELLOW}✅ ${#APPS[@]} aplicaciones desplegadas${NC}"
echo -e "${YELLOW}✅ Secrets de dev aplicados correctamente${NC}"
echo -e "${YELLOW}✅ ArgoCD funcionando${NC}"

echo -e "${GREEN}\n🔗 Accesos:${NC}"
echo -e "${YELLOW}👉 ArgoCD: https://localhost:8080${NC}"
echo -e "${YELLOW}👉 Usuario: admin | Contraseña arriba ⬆️${NC}"

echo -e "${GREEN}\n🔍 Comandos útiles:${NC}"
echo -e "${YELLOW}   kubectl get applications -n argocd${NC}"
echo -e "${YELLOW}   argocd app list${NC}"

echo -e "${GREEN}\n🔄 Port-forward PID: $PORT_FORWARD_PID${NC}"
echo -e "${YELLOW}Para detener: kill $PORT_FORWARD_PID${NC}"
