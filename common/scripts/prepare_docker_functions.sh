#!/bin/bash
set -e

OUTPUT_RED='\033[0;31m'
OUTPUT_GREEN='\033[0;32m'
OUTPUT_BLUE='\033[0;34m'
OUTPUT_PURPLE='\033[0;35m'
OUTPUT_PURPLE_UNDERLINED='\033[4;35m'
OUTPUT_RESET='\033[0m'

check_env () {
  if [[ ! -f .env ]] || [[ "$1" == "--help" ]]; then
    cat README.md
    exit 0
  fi
}

validate_ssl_config () {
  local sslCertConfigName=$1
  local sslKeyConfigName=$2

  echo "Validating SSL config..."

  if [[ ! -z $SSL_CONFIG ]] && [[ "$SSL_CONFIG" != "certs" && "$SSL_CONFIG" != "letsencrypt" ]]; then
    echo "Invalid SSL_CONFIG: $SSL_CONFIG"
    exit 255
  fi

  if [[ -z $SSL_CONFIG ]] || [[ "$SSL_CONFIG" == "letsencrypt" ]]; then
    if [[ -z $ACME_EMAIL ]]; then
      echo "ACME_EMAIL must be set to use letsencrypt"
      exit 255
    fi
  fi

  if [[ "$SSL_CONFIG" == "certs" ]]; then
    if [[ -z "${!sslCertConfigName}" || -z "${!sslKeyConfigName}" ]]; then
      echo "${sslCertConfigName} and ${sslKeyConfigName} must be set"
      exit 255
    fi
  fi
}

elevate_to_root () {
  echo "Elevating to root privileges..."
  if [[ "$OSTYPE" != "darwin"* && "$EUID" -ne 0 ]]; then
    sudo ELEVATED_TO_ROOT="true" "$0" "$@"
    exit $?
  else
    echo "  root privileges already granted"
  fi
}

is_elevated_to_root () {
  [ "$ELEVATED_TO_ROOT" == "true" ]
}

is_parameter_present () {
  local parameterName=$1

  local i=0;
  for param in "$@"; do
    if [ $i -ne 0 ] && [[ "$param" == *"$parameterName"* ]]; then
      true
      return
    fi
    i=$(($i+1))
  done
  false
}

get_parameter_value () {
  local parameterName=$1

  local i=0;
  for param in "$@"; do
    if [ $i -ne 0 ] && [[ "$param" == *"$parameterName"* ]]; then
      echo $param | cut -d '=' -f 2
      break
    fi
    i=$(($i+1))
  done
}

create_docker_network () {
  local networkName=$1
  
  local existingNetwork=$(docker network ls | tail -n +2 | tr -s ' ' | cut -d ' ' -f 2 | grep "^$networkName$")
  if [ "$networkName" != "$existingNetwork" ]; then
    echo "Creating docker network '${networkName}'"
    docker network create $networkName
  fi
}

prepare_data_dir () {
  local dataDir=$1
  local subDirs=${@:2}

  echo "Preparing data dir and subdirs..."
  for subDir in $subDirs; do
    mkdir -p "$dataDir/$subDir"
    echo "  $dataDir/$subDir"
  done

  if [[ "$OSTYPE" != "darwin"* ]]; then
    chown -R 65532:65532 "${dataDir}"
  fi
}

copy_common_assets () {
  if [[ -d ../common/assets ]]; then
    echo "Copying common assets..."
    mkdir -p ./assets
    cp -r ../common/assets/* ./assets
  fi
}

extract_file_from_image () {
  local imageName=$1
  local imageTag=$2
  local source="$3"
  local target="$4"

  echo "Extracting $source from docker image $imageName:$imageTag..."

  if [ -z "$(docker images | grep $imageName | grep $imageTag)" ]; then
    echo "Pulling docker image $imageName:$imageTag..."
    docker pull $imageName:$imageTag >/dev/null 2>&1
  fi

  rm -Rf $target
  docker rm -f config-extract-tmp >/dev/null 2>&1
  docker create --name config-extract-tmp $imageName:$imageTag >/dev/null 2>&1
  docker cp config-extract-tmp:$source "$target"
  docker rm -f config-extract-tmp >/dev/null 2>&1
}

read_config () {
  local configPath="$1"
  local jsonPath="$2"

  local value=$(jq "$jsonPath" "$configPath")
  echo "$value"
}

delete_config () {
  local configPath="$1"
  local jsonPath="$2"

  jq "del($jsonPath)" "$configPath"
}

move_rename_config () {
  local configPath="$1"
  local jsonPathFrom="$2"
  local jsonPathTo="$3"

  if [ "$(jq $jsonPathFrom $configPath)" != "null" ]; then
    echo "  $jsonPathFrom -> $jsonPathTo (moved/renamed)"
    jq "$jsonPathTo = $jsonPathFrom | del($jsonPathFrom)" "$configPath" > "$configPath.tmp" && mv "$configPath.tmp" "$configPath"
  fi
}

set_config () {
  local configPath="$1"
  local jsonPath="$2"
  local value="$3"
  local outputCfg="$4"

  if [ "$outputCfg" != "suppress" ]; then
    if [ "$outputCfg" == "secret" ]; then echo "  $jsonPath: ****"; else echo "  $jsonPath: $value"; fi
  fi
  jq "$jsonPath=$value" "$configPath" > "$configPath.tmp" && mv "$configPath.tmp" "$configPath"
}

set_config_if_field_exists () {
  local configPath="$1"
  local jsonPath="$2"
  local value="$3"
  local outputCfg="$4"

  if [ "$(jq $jsonPath $configPath)" != "null" ]; then
    set_config "$configPath" "$jsonPath" "$value" "$outputCfg"
  fi
}

set_config_if_present_in_env () {
  local configPath="$1"
  local envVariableName="$2" # name of env variable containing value
  local jsonPath="$3"        # jsonpath to set value in configuration
  local outputCfg="$4"

  local defaultValue=$(read_config "$configPath" "$jsonPath")
  if [ ! -z "${!envVariableName}" ]; then set_config "$configPath" "$jsonPath" "${!envVariableName:-$defaultValue}" "$outputCfg"; else echo "  $jsonPath: $defaultValue (default)"; fi
}

get_env_by_name () {
  local envVariableName="$1"
  local defaultValue="$2"
  echo "${!envVariableName:-$defaultValue}"
}

generate_random_string () {
  local stringLength=${1:-20}

  cat /dev/urandom | tr -dc '[:alpha:]' | fold -w ${1:-$stringLength} | head -n 1
}

print_line () {
  local columns="$1"
  printf '%*s\n' "${columns:-$(tput cols)}" '' | tr ' ' -
}

start_node () {
  if [ ! -z "$(docker compose ps | tail -n +3)" ]; then
      read -p "Node is already running. Restart? (y/n) " yn
      case $yn in
        y) stop_node
           ;;
        *) echo "Restart cancelled"
           exit 0
           ;;
      esac
  fi

  $(dirname "$0")/prepare_docker.sh
  docker compose down && docker compose up -d && docker compose logs -f
}

stop_node () {
  docker compose down
}

show_logs () {
  docker compose logs -f --tail 1000
}
