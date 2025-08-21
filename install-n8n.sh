#!/usr/bin/env bash
# n8n installer for Ubuntu 24.04 (Noble)
# - Instala Node.js LTS (18.x), n8n, PM2
# - Crea usuario dedicado 'n8n'
# - Arranca n8n con PM2 (arranque automático al boot)
# - (Opcional) Configura Nginx como reverse proxy + Let's Encrypt
# Autor: ChatGPT (para Sebastián)

set -euo pipefail

############### CONFIGURACIÓN EDITABLE ###############
DOMAIN="tu-dominio.com"          # ← Cambiá por tu dominio (requerido si ENABLE_SSL=true)
ADMIN_EMAIL="admin@tudominio.com" # ← Email para Let's Encrypt (requerido si ENABLE_SSL=true)
ENABLE_SSL=true                   # true|false (requiere dominio apuntando a este servidor)
N8N_PORT="5678"
N8N_PROTOCOL="http"               # http (detrás de Nginx irá con https)
N8N_HOST="0.0.0.0"                # 0.0.0.0 para exponer hacia Nginx
# Opcional: fija una URL pública si usarás HTTPS (recomendado para webhooks correctos)
# PUBLIC_URL="https://$DOMAIN"
PUBLIC_URL=""                     # déjalo vacío si no usarás HTTPS por ahora
#######################################################

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Este script debe ejecutarse como root (sudo)." >&2
    exit 1
  fi
}

msg() { echo -e "\n\033[1;32m[+] $*\033[0m\n"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err() { echo -e "\033[1;31m[✗] $*\033[0m" >&2; }

require_root

msg "Actualizando sistema…"
apt update -y && apt upgrade -y

msg "Instalando dependencias base…"
apt install -y curl build-essential git ca-certificates

if ! command -v node >/dev/null 2>&1; then
  msg "Instalando Node.js 18 LTS desde NodeSource…"
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt install -y nodejs
else
  msg "Node.js ya está instalado: $(node -v)"
fi

msg "Instalando n8n y PM2 globalmente…"
npm install -g n8n pm2

# Crear usuario dedicado n8n
if ! id n8n >/dev/null 2>&1; then
  msg "Creando usuario del sistema 'n8n'…"
  useradd -m -d /var/lib/n8n -s /bin/bash n8n
fi

# Preparar home y permisos
install -d -o n8n -g n8n /var/lib/n8n
cd /var/lib/n8n

# Archivo .env para n8n
msg "Creando archivo de entorno para n8n…"
ENV_FILE=/var/lib/n8n/.env
cat > "$ENV_FILE" <<EOF
# === n8n Environment ===
N8N_PORT=$N8N_PORT
N8N_PROTOCOL=$N8N_PROTOCOL
N8N_HOST=$N8N_HOST
EOF

# PUBLIC_URL si se definió
if [ -n "$PUBLIC_URL" ]; then
  echo "WEBHOOK_TUNNEL_URL=$PUBLIC_URL" >> "$ENV_FILE"
  echo "N8N_EDITOR_BASE_URL=$PUBLIC_URL" >> "$ENV_FILE"
  echo "N8N_PUBLIC_API_DISABLED=false" >> "$ENV_FILE"
fi

chown n8n:n8n "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Script de arranque que exporta env y lanza n8n
START_SH=/var/lib/n8n/start-n8n.sh
msg "Creando wrapper de arranque: $START_SH"
cat > "$START_SH" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
cd /var/lib/n8n
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi
exec n8n
EOS
chown n8n:n8n "$START_SH"
chmod +x "$START_SH"

# Iniciar n8n con PM2 como usuario n8n
msg "Iniciando n8n con PM2 (usuario 'n8n')…"
sudo -u n8n -H pm2 start "$START_SH" --name n8n || true
sudo -u n8n -H pm2 save

# Habilitar PM2 al boot para el usuario n8n
msg "Configurando PM2 para iniciar al boot…"
PM2_CMD=$(sudo -u n8n -H pm2 startup systemd -u n8n --hp /var/lib/n8n | tail -n 1 || true)
if [[ "$PM2_CMD" == sudo* ]]; then
  eval "$PM2_CMD"
else
  warn "No pude obtener el comando de pm2 startup. Continuando…"
fi

# (Opcional) Nginx + SSL
if [ "$ENABLE_SSL" = true ]; then
  if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "tu-dominio.com" ]; then
    err "ENABLE_SSL=true pero DOMAIN no está configurado. Editá el script y volvé a ejecutar."
    exit 1
  fi
  if [ -z "$ADMIN_EMAIL" ] || [[ "$ADMIN_EMAIL" != *"@"* ]]; then
    err "ENABLE_SSL=true pero ADMIN_EMAIL no es válido. Editá el script y volvé a ejecutar."
    exit 1
  fi

  msg "Instalando Nginx y Certbot…"
  apt install -y nginx certbot python3-certbot-nginx

  # Abrir firewall si UFW está activo
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      msg "UFW activo: habilitando puertos 80 y 443…"
      ufw allow 80/tcp || true
      ufw allow 443/tcp || true
    fi
  fi

  # Config Nginx
  NGINX_SITE=/etc/nginx/sites-available/n8n.conf
  msg "Creando configuración Nginx para $DOMAIN…"
  cat > "$NGINX_SITE" <<NGX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:$N8N_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
    }
}
NGX

  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/n8n.conf
  # Deshabilitar default si existe
  if [ -e /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  nginx -t
  systemctl reload nginx

  msg "Obteniendo certificado Let's Encrypt (puerto 80 debe estar accesible)…"
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" --redirect

  # Si configuraste SSL, recomendamos fijar PUBLIC_URL
  if [ -z "$PUBLIC_URL" ]; then
    warn "Sugerencia: establecé PUBLIC_URL=\"https://$DOMAIN\" en este script y re-ejecutá para setear correctamente WEBHOOK_TUNNEL_URL."
  fi
else
  warn "Saltando configuración de Nginx/SSL (ENABLE_SSL=false)."
  warn "Podés acceder a n8n en: http://<IP_SERVIDOR>:$N8N_PORT"
fi

msg "Instalación completada ✅"
echo "— n8n status:        sudo -u n8n -H pm2 status"
echo "— Ver logs:          sudo -u n8n -H pm2 logs n8n"
echo "— Reiniciar n8n:     sudo -u n8n -H pm2 restart n8n"
echo "— Ruta local:        http://127.0.0.1:$N8N_PORT"
if [ "$ENABLE_SSL" = true ]; then
  echo "— URL pública:       https://$DOMAIN"
else
  echo "— (Opcional) Luego podés activar Nginx+SSL: editá ENABLE_SSL=true y re-ejecutá este script."
fi
