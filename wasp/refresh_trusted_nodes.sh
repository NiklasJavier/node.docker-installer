#!/bin/bash
set -e
source ../common/scripts/prepare_docker_functions.sh
source .env
shopt -s expand_aliases

scriptDir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

alias wasp-cli="${scriptDir}/wasp-cli-wrapper.sh"

echo -e "${OUTPUT_PURPLE_UNDERLINED}HINT:${OUTPUT_RESET} Press CTRL+C if script hangs. Wasp is a little bit buggy at the moment. Restarting wasp can help at times."
echo -e ""

checkLogin=$(wasp-cli peering info || true)
if [[ "${checkLogin}" =~ "401" ]]; then
  echo "Seems you are not (yet) authenticated. Please input credentials to authenticate wasp API connection:"
  wasp-cli login
  echo "-----"
fi

trustedNodes=$(wasp-cli peering list-trusted)
if [[ "${trustedNodes}" != "" ]]; then
  echo "Distrusting currently trusted nodes first..."
  echo -e "${trustedNodes}" | sed '1,3d' | while read trustedNode ; do
    pubKey=$(echo ${trustedNode} | tr -s ' ' | cut -d ' ' -f 1)
    netId=$(echo ${trustedNode} | tr -s ' ' | cut -d ' ' -f 2)
    echo -e "  Processing ${netId}"
    echo -e "    ${OUTPUT_RED}skipped:${OUTPUT_RESET} Distrusting nodes is disabled at the moment (wasp not working correctly yet)"
    # wasp-cli peering distrust "$netId" | while read line ; do
    #   if [[ "$line" =~ "error" ]]; then 
    #     echo -e "    ${OUTPUT_RED}$line${OUTPUT_RESET}"
    #   else
    #     echo -e "    ${OUTPUT_GREEN}$line${OUTPUT_RESET}"
    #   fi
    # done
  done
  echo ""
fi

trap_ctrl_c () {
  echo -e "\n-----"
  echo -e "${OUTPUT_RED}Script aborted by user.${OUTPUT_RESET}"
  echo -e "Consider restarting wasp to fix unexpected behaviour of this script."
}

echo "Adding nodes that are defined in .env..."
for trustedNodeNetId in $(grep -E "^WASP_TRUSTED_NODE_[0-9]+_NETID" .env); do
  trustedNodeNumber=$(echo ${trustedNodeNetId} | cut -d '_' -f 4)
  netId=$(grep -E "WASP_TRUSTED_NODE_${trustedNodeNumber}_NETID" .env | cut -d '=' -f 2)
  pubKey=$(grep -E "WASP_TRUSTED_NODE_${trustedNodeNumber}_PUBKEY" .env | cut -d '=' -f 2)
  echo "  Processing ${netId}"

  trap trap_ctrl_c INT

  wasp-cli peering trust "${pubKey}" "${netId}" | while read line ; do
      if [[ "${line}" =~ "error" ]]; then 
        echo -e "    ${OUTPUT_RED}${line}${OUTPUT_RESET}"
      else
        echo -e "    ${OUTPUT_BLUE}${line}${OUTPUT_RESET}"
      fi
  done

  status=$?
  [ ${status} -eq 0 ] && echo -e "    ${OUTPUT_GREEN}success${OUTPUT_RESET}" || echo "    ${OUTPUT_RED}failed${OUTPUT_RESET}"
done
echo ""

echo "Current trused nodes:"
wasp-cli peering list-trusted | sed '3d' | sed '1d' | while read line ; do echo -e "  $line"; done
