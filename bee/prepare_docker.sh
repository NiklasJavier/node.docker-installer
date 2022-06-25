#!/bin/bash

if [[ ! -f .env ]] || [[ "$1" == "--help" ]]; then
  cat README.md
  exit 0
fi

if [[ "$OSTYPE" != "darwin"* && "$EUID" -ne 0 ]]; then
  echo "Please run as root or with sudo"
  exit
fi

source $(dirname "$0")/.env

scriptDir=$(dirname "$0")
beeImage="iotaledger/bee:$BEE_VERSION"
configFilename="config.chrysalis-${BEE_NETWORK:-mainnet}.json"
configPath="$scriptDir/data/config/$configFilename"


# Prepare for SSL (fake cert and key is used to prevent docker-compose failures on usage of letsencrypt)
mkdir -p /tmp/bee && touch /tmp/bee/fake.cert && touch /tmp/bee/fake.key

if [[ ! -z $SSL_CONFIG ]] && [[ "$SSL_CONFIG" != "certs" && "$SSL_CONFIG" != "letsencrypt" ]]; then
  echo "Invalid SSL_CONFIG: $SSL_CONFIG"
  exit -1
fi


if [[ -z $SSL_CONFIG ]] || [[ "$SSL_CONFIG" == "letsencrypt" ]]; then
 if [[ -z $ACME_EMAIL ]]; then
   echo "ACME_EMAIL must be set to use letsencrypt"
   exit -1
 fi
fi

if [[ "$SSL_CONFIG" == "certs" ]]; then
 if [[ -z $BEE_SSL_CERT || -z $BEE_SSL_KEY ]]; then
   echo "BEE_SSL_CERT and BEE_SSL_KEY must be set"
   exit -1
 fi
fi


# Prepare db directory
mkdir -p data
mkdir -p data/config
mkdir -p data/storage
mkdir -p data/snapshots
mkdir -p data/letsencrypt

if [[ "$OSTYPE" != "darwin"* ]]; then
  chown -R 65532:65532 data
fi


# Extract default config from image
echo "Generating config..."
rm -f $(dirname "$configPath")/*
containerId=$(docker create $beeImage)
docker cp $containerId:/app/$configFilename "$configPath"
docker rm $containerId


# Update extracted config with values from .env
tmp=/tmp/config.tmp
jq ".network.bindAddress=\"/ip4/0.0.0.0/tcp/${BEE_GOSSIP_PORT:-15600}\"" "$configPath" > "$tmp" && mv "$tmp" "$configPath"
jq ".autopeering.bindAddress=\"0.0.0.0:${BEE_AUTOPEERING_PORT:-14626}\"" "$configPath" > "$tmp" && mv "$tmp" "$configPath"
jq ".autopeering.enabled=true" "$configPath" > "$tmp" && mv "$tmp" "$configPath"
jq ".dashboard.auth.user=\"${DASHBOARD_USERNAME:-admin}\"" "$configPath" > "$tmp" && mv "$tmp" "$configPath"
jq ".dashboard.auth.passwordHash=\"$DASHBOARD_PASSWORD\"" "$configPath" > "$tmp" && mv "$tmp" "$configPath"
jq ".dashboard.auth.passwordSalt=\"$DASHBOARD_SALT\"" "$configPath" > "$tmp" && mv "$tmp" "$configPath"
rm -f $tmp

echo "Finished"
