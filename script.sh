#!/bin/bash
# 🚀 Script GitOps para AWS EKS - Entorno TEST (con extracción segura de secrets)

set -e

# 🎨 Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}\n🌥️ INICIANDO DESPLIEGUE EN AWS EKS - TEST${NC}"

# --------------------------------------------
# 🔐 Función para extraer valores de SealedSecrets
# --------------------------------------------
extract_sealed_value() {
    local secret_name=$1
    local key_name=$2
    local namespace=$3
    
    # Verificar que tenemos la clave privada
    if [ ! -f "sealed-secrets-private-key-backup.yaml" ]; then
        echo -e "${RED}❌ Error: No se encontró sealed-secrets-private-key-backup.yaml${NC}"
        return 1
    fi
    
    # Obtener el valor encriptado del SealedSecret
    encrypted_value=$(kubectl get sealedsecret $secret_name -n $namespace -o jsonpath="{.spec.encryptedData.$key_name}" 2>/dev/null)
    
    if [ -z "$encrypted_value" ]; then
        echo -e "${YELLOW}⚠️  No se pudo obtener el valor encriptado de $key_name${NC}"
        return 1
    fi
    
    # Crear un SealedSecret temporal para desencriptar
    cat <<EOF > /tmp/temp-sealed-secret.yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: temp-secret
  namespace: $namespace
spec:
  encryptedData:
    $key_name: $encrypted_value
EOF

    # Desencriptar usando kubeseal
    decrypted_value=$(kubeseal --recovery-unseal --recovery-private-key sealed-secrets-private-key-backup.yaml < /tmp/temp-sealed-secret.yaml 2>/dev/null | jq -r ".spec.template.data.\"$key_name\"")
    
    rm -f /tmp/temp-sealed-secret.yaml
    
    if [ -z "$decrypted_value" ]; then
        echo -e "${RED}❌ Error al desencriptar $key_name${NC}"
        return 1
    fi
    
    echo "$decrypted_value"
}

# --------------------------------------------
# 1. Verificar conexión al Cluster
# --------------------------------------------
echo -e "${BLUE}🔍 Verificando acceso a EKS...${NC}"
if ! kubectl cluster-info > /dev/null 2>&1; then
  echo -e "${RED}❌ No se puede acceder al cluster. Verifica tu contexto kubectl.${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Conectado al cluster EKS${NC}"
fi

# --------------------------------------------
# 2. Intentar obtener credenciales automáticamente
# --------------------------------------------
echo -e "${BLUE}\n🔓 Intentando obtener credenciales de la base de datos...${NC}"

# Verificar si el SealedSecret existe
if kubectl get sealedsecret backend-secrets -n test >/dev/null 2>&1; then
    echo -e "${GREEN}✅ SealedSecret 'backend-secrets' encontrado en test${NC}"
    
    # Extraer DB_USER
    DB_USER=$(extract_sealed_value "backend-secrets" "DB_USER" "test")
    if [ $? -ne 0 ] || [ -z "$DB_USER" ]; then
        read -p "🔑 Ingrese DB_USER manualmente: " DB_USER
    fi
    
    # Extraer DB_PASSWORD
    DB_PASSWORD=$(extract_sealed_value "backend-secrets" "DB_PASSWORD" "test")
    if [ $? -ne 0 ] || [ -z "$DB_PASSWORD" ]; then
        read -s -p "🔑 Ingrese DB_PASSWORD manualmente: " DB_PASSWORD
        echo ""
    fi
else
    echo -e "${YELLOW}⚠️  SealedSecret 'backend-secrets' no encontrado, solicitando credenciales manualmente${NC}"
    read -p "🔑 Ingrese DB_USER: " DB_USER
    read -s -p "🔑 Ingrese DB_PASSWORD: " DB_PASSWORD
    echo ""
fi

# Hardcoded RDS endpoint
DB_HOST="atalesdb.crxuvzgv6rwg.us-east-1.rds.amazonaws.com"

echo -e "${GREEN}✅ Credenciales obtenidas${NC}"
echo -e "${YELLOW}ℹ️  Usando RDS endpoint: ${DB_HOST}${NC}"

# --------------------------------------------
# 3. Sealed Secrets Controller
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
# 4. Namespace
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
# 5. Aplicar Sealed Secrets
# --------------------------------------------
echo -e "${BLUE}\n🔑 Aplicando Sealed Secrets...${NC}"
kubectl apply -k sealed-secrets/$NAMESPACE/

# Esperar a que los secrets estén disponibles
echo -e "${BLUE}⏳ Esperando a que los secrets estén listos...${NC}"
sleep 10

# --------------------------------------------
# 6. Instalar ArgoCD
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
# 7. Desplegar Aplicaciones
# --------------------------------------------
echo -e "${BLUE}\n🚀 Desplegando aplicaciones en ArgoCD...${NC}"
for app in argo-apps/*; do
  kubectl apply -f "$app" -n argocd
done

# --------------------------------------------
# 8. Crear entrada en /etc/hosts
# --------------------------------------------
echo -e "${BLUE}\n🌐 Configurando /etc/hosts...${NC}"

FRONTEND_LB=$(kubectl get svc frontend-service -n test -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

if [ -z "$FRONTEND_LB" ]; then
  echo -e "${RED}❌ No se encontró el LoadBalancer del frontend. Asegurate que esté creado.${NC}"
else
  if grep -q "atales.localaws" /etc/hosts; then
    sudo sed -i "/atales.localaws/c\\$FRONTEND_LB atales.localaws" /etc/hosts
    echo -e "${YELLOW}🟡 Entrada en /etc/hosts actualizada${NC}"
  else
    echo "$FRONTEND_LB atales.localaws" | sudo tee -a /etc/hosts > /dev/null
    echo -e "${GREEN}✅ Entrada agregada en /etc/hosts: atales.localaws${NC}"
  fi
fi

# --------------------------------------------
# 9. Port-forward ArgoCD
# --------------------------------------------
echo -e "${YELLOW}\n🚪 Habilitando acceso a ArgoCD con port-forward...${NC}"
pkill -f "kubectl port-forward.*argocd-server" 2>/dev/null || true
sleep 2
kubectl port-forward svc/argocd-server -n argocd 8080:443 > /dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 3

echo -e "${GREEN}\n🔗 Acceso a ArgoCD: https://localhost:8080${NC}"
echo -e "${YELLOW}🔑 Usuario: admin${NC}"
echo -e "${YELLOW}🔑 Contraseña:${NC}"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# --------------------------------------------
# 10. Crear DB en RDS
# --------------------------------------------
echo -e "${BLUE}\n🗄️ Verificando base de datos 'atalesdb' en RDS...${NC}"

if kubectl run mysql-client --rm -i --tty --image=mysql:8.0 --restart=Never -- bash -c \
"mysql -h $DB_HOST -u$DB_USER -p$DB_PASSWORD -e 'CREATE DATABASE IF NOT EXISTS atalesdb; SHOW DATABASES;'"; then
  echo -e "${GREEN}✅ Base de datos 'atalesdb' verificada/creada en ${DB_HOST}${NC}"
else
  echo -e "${RED}❌ Error al conectar con la base de datos. Verifica las credenciales.${NC}"
fi

# --------------------------------------------
# 11. Fin
# --------------------------------------------
echo -e "${GREEN}\n🚀 DESPLIEGUE COMPLETO EN EKS - TEST${NC}"
echo -e "${GREEN}✅ Acceso frontend: http://atales.localaws${NC}"
echo -e "${GREEN}✅ Acceso ArgoCD: https://localhost:8080${NC}"
echo -e "${YELLOW}ℹ️  RDS endpoint: ${DB_HOST}${NC}"
echo -e "${YELLOW}ℹ️  DB User: ${DB_USER}${NC}"
echo -e "${YELLOW}Para detener port-forward: kill $PORT_FORWARD_PID${NC}"