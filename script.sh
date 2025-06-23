#!/bin/bash

# 🚀 Script de Despliegue Local Optimizado - Versión Final
set -e

# 🎨 Colores para mensajes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}\n🌐 INICIANDO DESPLIEGUE EN MINIKUBE${NC}"

# --------------------------------------------
# 1. CONFIGURACIÓN INICIAL
# --------------------------------------------
echo -e "${BLUE}\n🔍 Verificando Minikube...${NC}"
if ! minikube status > /dev/null 2>&1; then
  echo -e "${YELLOW}🟡 Iniciando Minikube (3 CPUs, 4500MB RAM)...${NC}"
  minikube start --cpus=3 --memory=4500mb --driver=docker \
    --extra-config=kubelet.housekeeping-interval=10s \
    --extra-config=kubelet.max-pods=50
else
  echo -e "${GREEN}✅ Minikube ya está activo${NC}"
fi

# Configurar Docker
eval "$(minikube docker-env)"
docker system prune -f
echo -e "${GREEN}✅ Docker configurado${NC}"

# --------------------------------------------
# 2. CONFIGURACIÓN DE RED
# --------------------------------------------
MINIKUBE_IP=$(minikube ip)
echo -e "${GREEN}\n📌 IP de Minikube: ${BLUE}$MINIKUBE_IP${NC}"

HOST_ENTRY="$MINIKUBE_IP atales.local"
if ! grep -q "atales.local" /etc/hosts; then
  echo -e "${YELLOW}🔧 Actualizando /etc/hosts...${NC}"
  echo "$HOST_ENTRY" | sudo tee -a /etc/hosts > /dev/null
fi

# Habilitar Ingress
minikube addons enable ingress
sleep 15

# --------------------------------------------
# 3. CONSTRUIR IMÁGENES
# --------------------------------------------
echo -e "${BLUE}\n🐳 Construyendo imágenes...${NC}"

build_image() {
  echo -e "${GREEN}📦 Construyendo $1...${NC}"
  docker build -t $1:local -f $2/Dockerfile $2
}

# Construir auth-service
echo -e "${GREEN}📦 Construyendo auth-service...${NC}"
(cd ../proyecto-Atales/backend && docker build -t auth-service:local -f auth-service/Dockerfile .)

# Construir business-service
echo -e "${GREEN}📦 Construyendo business-service...${NC}"
(cd ../proyecto-Atales/backend && docker build -t business-service:local -f negocio-service/Dockerfile .)

# Construir api-gateway
echo -e "${GREEN}📦 Construyendo api-gateway...${NC}"
docker build -t api-gateway:local -f ../proyecto-Atales/backend/api-gateway/Dockerfile ../proyecto-Atales/backend/api-gateway

# --------------------------------------------
# 4. CERT-MANAGER
# --------------------------------------------
echo -e "${BLUE}\n🔐 Configurando cert-manager...${NC}"
if ! kubectl get ns cert-manager &> /dev/null; then
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.3/cert-manager.yaml
  kubectl wait --for=condition=Available apiservice v1.cert-manager.io --timeout=180s
fi

# --------------------------------------------
# 5. DESPLIEGUE EN ORDEN CORRECTO
# --------------------------------------------
echo -e "${GREEN}\n🚀 INICIANDO DESPLIEGUE KUBERNETES${NC}"

# Limpieza completa
echo -e "${YELLOW}🧹 Limpiando namespace dev...${NC}"
kubectl delete namespace dev --ignore-not-found=true
kubectl create namespace dev

# Paso 1: Secret
echo -e "${BLUE}\n🔑 Aplicando secret...${NC}"
kubectl apply -f overlays/dev/secret-backend.yaml -n dev

# Paso 2: PVC para MySQL (con espera mejorada)
echo -e "${BLUE}\n💾 Aplicando PVC para MySQL...${NC}"
kubectl apply -f base/pvc-mysql.yaml -n dev

# Espera mejorada para PVC
echo -e "${YELLOW}⏳ Esperando a que el PVC esté Bound...${NC}"
while [[ $(kubectl get pvc/mysql-pvc -n dev -o 'jsonpath={..status.phase}') != "Bound" ]]; do
  sleep 5
  echo -n "."
done
echo -e "\n${GREEN}✅ PVC listo${NC}"

# Paso 3: MySQL
echo -e "${BLUE}\n🗄️ Desplegando MySQL...${NC}"
kubectl apply -f base/deployment-mysql.yaml -n dev
kubectl wait --for=condition=Ready pod -n dev -l app=mysql --timeout=300s

# Paso 4: Todo lo demás
echo -e "${BLUE}\n🌐 Aplicando configuración completa...${NC}"
kubectl apply -k overlays/dev -n dev

# --------------------------------------------
# 6. VERIFICACIÓN FINAL
# --------------------------------------------
echo -e "${BLUE}\n⏳ Esperando a que todos los servicios estén listos...${NC}"

# Función mejorada para esperar deployments
wait_for_deployment() {
  local deployment=$1
  local timeout=180
  local start_time=$(date +%s)
  
  while :; do
    current_status=$(kubectl get deployment/$deployment -n dev -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
    [[ "$current_status" == "True" ]] && break
    
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    
    if ((elapsed >= timeout)); then
      echo -e "${RED}❌ Timeout esperando por $deployment${NC}"
      kubectl describe deployment/$deployment -n dev
      exit 1
    fi
    
    sleep 5
  done
}

# Esperar por cada deployment
deployments=("api-gateway" "auth-service" "business-service" "frontend")
for dep in "${deployments[@]}"; do
  wait_for_deployment $dep
done

# Estado final
echo -e "${GREEN}\n📊 ESTADO FINAL DEL CLUSTER:${NC}"
kubectl get all,ingress,pvc -n dev

# URLs de acceso
echo -e "${GREEN}\n🌍 URLs DE ACCESO:${NC}"
echo -e "  - Frontend:    ${BLUE}http://atales.local${NC}"
echo -e "  - API Gateway: ${BLUE}http://atales.local/api/health${NC}"

echo -e "${YELLOW}\n🔌 Para exponer los servicios ejecuta en otra terminal:${NC}"
echo -e "  minikube tunnel"
echo -e "${YELLOW}💡 Presiona Ctrl+C para detener el tunnel cuando termines${NC}"

echo -e "${GREEN}\n🎉 ¡DESPLIEGUE COMPLETADO CON ÉXITO! 🎉${NC}"
