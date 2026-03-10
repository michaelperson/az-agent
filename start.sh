#!/bin/bash
set -e

if [ -z "$AZP_URL" ]; then
  echo 1>&2 "Erreur : la variable d'environnement AZP_URL est manquante."
  exit 1
fi

if [ -z "$AZP_TOKEN_FILE" ]; then
  if [ -z "$AZP_TOKEN" ]; then
    echo 1>&2 "Erreur : la variable d'environnement AZP_TOKEN est manquante."
    exit 1
  fi

  AZP_TOKEN_FILE=/azp/.token
  echo -n $AZP_TOKEN > "$AZP_TOKEN_FILE"
fi

unset AZP_TOKEN

if [ -n "$AZP_WORK" ]; then
  mkdir -p "$AZP_WORK"
fi

export AGENT_ALLOW_RUNASROOT="1"

cleanup() {
  if [ -e config.sh ]; then
    echo "Nettoyage. Suppression de l'agent Azure Pipelines..."
    while true; do
      ./config.sh remove --unattended --auth pat --token $(cat "$AZP_TOKEN_FILE") && break
      echo "Nouvelle tentative dans 30 secondes..."
      sleep 30
    done
  fi
}

export VSO_AGENT_IGNORE=AZP_TOKEN,AZP_TOKEN_FILE

# ─────────────────────────────────────────
# PRÉ-INSTALLATION : Node.js + outils
# ─────────────────────────────────────────
echo "0. Installation de Node.js et des outils nécessaires..."

# Installer Node.js v20 via NodeSource
if ! command -v node &> /dev/null || [[ "$(node -v)" != v20* ]]; then
  echo "   → Installation de Node.js 20..."
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
else
  echo "   → Node.js $(node -v) déjà installé, skip."
fi

echo "   → Node.js : $(node -v)"
echo "   → npm     : $(npm -v)"
echo "   → ESLint  : $(eslint --version)"
echo "   → Sonar   : $(sonar-scanner -v 2>&1 | grep -i 'sonarscanner\|version' | head -1)"
echo "   → Docker  : $(docker --version)"
echo "✅ Outils prêts."

# ─────────────────────────────────────────

echo "1. Détermination de l'agent Azure Pipelines correspondant..."
AZP_AGENT_PACKAGES=$(curl -LsS \
    -u user:$(cat "$AZP_TOKEN_FILE") \
    -H 'Accept:application/json;' \
    "$AZP_URL/_apis/distributedtask/packages/agent?platform=linux-x64&top=1")

AZP_AGENT_PACKAGE_LATEST_URL=$(echo "$AZP_AGENT_PACKAGES" | jq -r '.value[0].downloadUrl')

if [ -z "$AZP_AGENT_PACKAGE_LATEST_URL" -o "$AZP_AGENT_PACKAGE_LATEST_URL" == "null" ]; then
  echo 1>&2 "Erreur : impossible de déterminer l'URL de téléchargement de l'agent."
  exit 1
fi

echo "2. Téléchargement et extraction de l'agent..."
curl -LsS $AZP_AGENT_PACKAGE_LATEST_URL | tar -xz

source ./env.sh

echo "3. Configuration de l'agent Azure Pipelines..."
./config.sh --unattended \
  --agent "${AZP_AGENT_NAME:-$(hostname)}" \
  --url "$AZP_URL" \
  --auth pat \
  --token $(cat "$AZP_TOKEN_FILE") \
  --pool "${AZP_POOL:-Default}" \
  --work "${AZP_WORK:-_work}" \
  --replace \
  --acceptTeeEula

echo "4. Exécution de l'agent..."
trap 'cleanup; exit 0' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

chmod +x ./run-docker.sh
./run-docker.sh "$@"