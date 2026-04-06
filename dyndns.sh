#!/bin/bash
# DynDNS Script for Hetzner DNS API by FarrowStrange
# v2.0

auth_api_token=${HETZNER_AUTH_API_TOKEN:-''}
zone_name=${HETZNER_ZONE_NAME:-''}
zone_id=${HETZNER_ZONE_ID:-''}
record_name=${HETZNER_RECORD_NAME:-''}
record_ttl=${HETZNER_RECORD_TTL:-'60'}
record_type=${HETZNER_RECORD_TYPE:-'A'}
record_ip=${HETZNER_RECORD_IP:-''}

display_help() {
  cat <<EOF

exec: ./dyndns.sh [ -z <Zone ID> | -Z <Zone Name> ] -n <Record Name>

parameters:
  -z  - Zone ID
  -Z  - Zone name
  -n  - Record name

optional parameters:
  -i  - IP address (skips auto-detection via ip.hetzner.com)
  -t  - TTL (Default: 60)
  -T  - Record type (Default: A)

help:
  -h  - Show Help

requirements:
  curl
  jq

example:
  .exec: ./dyndns.sh -z 98jFjsd8dh1GHasdf7a8hJG7 -n dyn
  .exec: ./dyndns.sh -Z example.com -n dyn -T AAAA

EOF
  exit 1
}

logger() {
  echo "${1}: Record_Name: ${record_name} : ${2}"
}

fail() {
  logger Error "${1}"
  exit 1
}

api()       { curl -s -w "\n%{http_code}" -H 'Content-Type: application/json' -H "Authorization: Bearer ${auth_api_token}" "$@"; }
http_code() { echo "$1" | tail -n 1; }
http_body() { echo "$1" | sed '$d'; }

while getopts ":z:Z:n:i:t:T:h" opt; do
  case "$opt" in
    z  ) zone_id="${OPTARG}";;
    Z  ) zone_name="${OPTARG}";;
    n  ) record_name="${OPTARG}";;
    i  ) record_ip="${OPTARG}";;
    t  ) record_ttl="${OPTARG}";;
    T  ) record_type="${OPTARG}";;
    h  ) display_help;;
    \? ) echo "Invalid option: -$OPTARG" >&2; exit 1;;
    :  ) echo "Missing option argument for -$OPTARG" >&2; exit 1;;
    *  ) echo "Unimplemented option: -$OPTARG" >&2; exit 1;;
  esac
done

for cmd in curl jq; do
  command -v "${cmd}" &>/dev/null || fail "'${cmd}' is required but not installed."
done

[[ -z "${auth_api_token}" ]] && fail "No Auth API Token specified."
[[ -z "${record_name}" ]]    && fail "Missing option for record name: -n <Record Name>"

# get all zones
zone_info=$(curl -s --location \
          "https://api.hetzner.cloud/v1/zones" \
          --header "Authorization: Bearer ${auth_api_token}")

# check if either zone_id or zone_name is correct
if [[ -z "$(echo "${zone_info}" | jq --raw-output '.zones[] | select(.name=="'${zone_name}'") | .id')" && \
      -z "$(echo "${zone_info}" | jq --raw-output '.zones[] | select(.id=="'${zone_id}'") | .name')" ]]; then
  fail "Could not find Zone ID. Check your inputs of either -z <Zone ID> or -Z <Zone Name>."
fi

[[ -z "${zone_id}" ]]   && zone_id=$(echo "${zone_info}"   | jq --raw-output '.zones[] | select(.name=="'${zone_name}'") | .id')
[[ -z "${zone_name}" ]] && zone_name=$(echo "${zone_info}" | jq --raw-output '.zones[] | select(.id=="'${zone_id}'") | .name')

logger Info "Zone_ID: ${zone_id}"
logger Info "Zone_Name: ${zone_name}"

# get current public ip address
if [[ -n "${record_ip}" ]]; then
  cur_pub_addr="${record_ip}"
  logger Info "Using provided IP address: ${cur_pub_addr}"
elif [[ "${record_type}" == "AAAA" ]]; then
  logger Info "Using IPv6, because AAAA was set as record type."
  cur_pub_addr=$(curl -s6 https://ip.hetzner.com | grep -E '^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$')
  [[ -z "${cur_pub_addr}" ]] && fail "It seems you don't have a IPv6 public address."
  logger Info "Current public IP address: ${cur_pub_addr}"
elif [[ "${record_type}" == "A" ]]; then
  logger Info "Using IPv4, because A was set as record type."
  cur_pub_addr=$(curl -s4 https://ip.hetzner.com | grep -E '^([0-9]+(\.|$)){4}')
  [[ -z "${cur_pub_addr}" ]] && fail "Apparently there is a problem in determining the public ip address."
  logger Info "Current public IP address: ${cur_pub_addr}"
else
  fail "Only record type \"A\" or \"AAAA\" are supported for DynDNS."
fi

# check if record exists and get current value if so
record_zone=$(api --request GET "https://api.hetzner.cloud/v1/zones/${zone_id}/rrsets/${record_name}/${record_type}")
code=$(http_code "${record_zone}")

if [[ "${code}" == "404" ]]; then
  logger Info "DNS record \"${record_name}\" does not exist - will be created."
  response=$(api -X POST "https://api.hetzner.cloud/v1/zones/${zone_id}/rrsets" \
    -d $'{
      "name": "'${record_name}'",
      "type": "'${record_type}'",
      "ttl": '${record_ttl}',
      "records": [{"value": "'${cur_pub_addr}'"}],
      "labels": {"environment": "dyndns"}
    }')
  create_code=$(http_code "${response}")
  [[ "${create_code}" != "201" ]] && fail "HTTP ${create_code} - Unable to create record: \"${record_name}\""
  logger Info "DNS record \"${record_name}\" created successfully"
elif [[ "${code}" != "200" ]]; then
  fail "HTTP ${code} - Aborting run to prevent multiple records."
else
  cur_dyn_addr=$(http_body "${record_zone}" | jq --raw-output '.rrset.records[0].value')
  logger Info "Currently set IP address: ${cur_dyn_addr}"
  if [[ "${cur_pub_addr}" == "${cur_dyn_addr}" ]]; then
    logger Info "DNS record \"${record_name}\" is up to date - nothing to do."
    exit 0
  fi

  logger Info "DNS record \"${record_name}\" is no longer valid - updating record"
  response=$(api -X POST "https://api.hetzner.cloud/v1/zones/${zone_id}/rrsets/${record_name}/${record_type}/actions/set_records" \
    -d $'{"records": [{"value": "'${cur_pub_addr}'"}]}')
  update_code=$(http_code "${response}")
  [[ "${update_code}" != "200" ]] && fail "HTTP ${update_code} - Unable to update record: \"${record_name}\""
  logger Info "DNS record \"${record_name}\" updated successfully"
fi
