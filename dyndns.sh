#!/bin/sh
# DynDNS Script for Hetzner DNS API by FarrowStrange
# v1.3

# Initialize variables
auth_api_token=${HETZNER_AUTH_API_TOKEN:-""}  # Use the environment variable if set
zone_name=""
zone_id=""
record_name=""
record_ttl="60"
record_type="A"
record_id=""

# Function to display help
display_help() {
  cat <<EOF

Usage: ./dyndns.sh [ -a <API Token> ] [ -z <Zone ID> | -Z <Zone Name> ] -r <Record ID> -n <Record Name>

Parameters:
  -a  - Auth API Token (optional, can be set via env var HETZNER_AUTH_API_TOKEN)
  -z  - Zone ID
  -Z  - Zone name
  -r  - Record ID
  -n  - Record name

Optional parameters:
  -t  - TTL (Default: 60)
  -T  - Record type (Default: A)

Help:
  -h  - Show help 

Requirements:
  curl
  jq

Example:
  ./dyndns.sh -a your-api-token -z 98jFjsd8dh1GHasdf7a8hJG7 -r AHD82h347fGAF1 -n dyn
  ./dyndns.sh -Z example.com -n dyn -T AAAA

EOF
  exit 1
}

logger() {
  echo "${1}: Record_Name: ${record_name} : ${2}"
}

# Process command-line arguments
while getopts ":a:z:Z:r:n:t:T:h" opt; do
  case "$opt" in
    a  ) auth_api_token="${OPTARG}";;
    z  ) zone_id="${OPTARG}";;
    Z  ) zone_name="${OPTARG}";;
    r  ) record_id="${OPTARG}";;
    n  ) record_name="${OPTARG}";;
    t  ) record_ttl="${OPTARG}";;
    T  ) record_type="${OPTARG}";;
    h  ) display_help;;
    \? ) echo "Invalid option: -$OPTARG" >&2; exit 1;;
    :  ) echo "Missing option argument for -$OPTARG" >&2; exit 1;;
    *  ) echo "Unimplemented option: -$OPTARG" >&2; exit 1;;
  esac
done

# Check if required parameters are provided
if [ -z "${auth_api_token}" ]; then
  logger "Error" "No Auth API Token specified. Use -a <API Token> or set the HETZNER_AUTH_API_TOKEN environment variable."
  display_help
  exit 1
fi

if [ -z "${zone_id}" ] && [ -z "${zone_name}" ]; then
  logger "Error" "Either Zone ID (-z) or Zone Name (-Z) must be provided."
  display_help
  exit 1
fi

if [ -z "${record_name}" ]; then
  logger "Error" "Record name (-n) is required."
  display_help
  exit 1
fi

# Check if tools are installed
for cmd in curl jq; do
  if ! command -v "${cmd}" &> /dev/null; then
    logger "Error" "The script requires '${cmd}' but it seems not to be installed."
    exit 1
  fi
done

# Fetch all zones using the API
zone_info=$(curl -s --location \
          "https://dns.hetzner.com/api/v1/zones" \
          --header "Auth-API-Token: ${auth_api_token}")

# Check if either zone_id or zone_name is valid
if [ -z "$(echo "${zone_info}" | jq --raw-output ".zones[] | select(.name==\"${zone_name}\") | .id")" ] && \
   [ -z "$(echo "${zone_info}" | jq --raw-output ".zones[] | select(.id==\"${zone_id}\") | .name")" ]; then
  logger "Error" "Could not find Zone ID. Check your inputs for -z (Zone ID) or -Z (Zone Name)."
  exit 1
fi

# Fetch zone_id if zone_name is provided
if [ -z "${zone_id}" ]; then
  zone_id=$(echo "${zone_info}" | jq --raw-output ".zones[] | select(.name==\"${zone_name}\") | .id")
fi

# Fetch zone_name if zone_id is provided
if [ -z "${zone_name}" ]; then
  zone_name=$(echo "${zone_info}" | jq --raw-output ".zones[] | select(.id==\"${zone_id}\") | .name")
fi

logger "Info" "Zone_ID: ${zone_id}"
logger "Info" "Zone_Name: ${zone_name}"

# Get current public IP address based on record type
if [ "${record_type}" = "AAAA" ]; then
  logger "Info" "Using IPv6 (AAAA record type)."
  cur_pub_addr=$(curl -s6 https://ip.hetzner.com | grep -E '^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$')
elif [ "${record_type}" = "A" ]; then
  logger "Info" "Using IPv4 (A record type)."
  cur_pub_addr=$(curl -s4 https://ip.hetzner.com | grep -E '^([0-9]+(\.|$)){4}')
else
  logger "Error" "Only A or AAAA record types are supported."
  exit 1
fi

if [ -z "${cur_pub_addr}" ]; then
  logger "Error" "Unable to determine public IP address."
  exit 1
fi

logger "Info" "Current public IP address: ${cur_pub_addr}"

# Fetch record ID if not provided
if [ -z "${record_id}" ]; then
  record_zone=$(curl -s --location \
                 --request GET "https://dns.hetzner.com/api/v1/records?zone_id=${zone_id}" \
                 --header "Auth-API-Token: ${auth_api_token}")
  
  record_id=$(echo "${record_zone}" | jq --raw-output ".records[] | select(.type==\"${record_type}\") | select(.name==\"${record_name}\") | .id")
fi

logger "Info" "Record_ID: ${record_id}"

# Create or update the DNS record
if [ -z "${record_id}" ]; then
  logger "Info" "DNS record \"${record_name}\" does not exist. Creating a new record."
  curl -s -X "POST" "https://dns.hetzner.com/api/v1/records" \
       -H "Content-Type: application/json" \
       -H "Auth-API-Token: ${auth_api_token}" \
       -d "{
          \"value\": \"${cur_pub_addr}\",
          \"ttl\": ${record_ttl},
          \"type\": \"${record_type}\",
          \"name\": \"${record_name}\",
          \"zone_id\": \"${zone_id}\"
        }"
else
  cur_dyn_addr=$(curl -s "https://dns.hetzner.com/api/v1/records/${record_id}" \
                 -H "Auth-API-Token: ${auth_api_token}" | jq --raw-output '.record.value')
  
  if [ "${cur_pub_addr}" = "${cur_dyn_addr}" ]; then
    logger "Info" "DNS record \"${record_name}\" is up-to-date. No changes needed."
  else
    logger "Info" "Updating DNS record \"${record_name}\"."
    curl -s -X "PUT" "https://dns.hetzner.com/api/v1/records/${record_id}" \
         -H "Content-Type: application/json" \
         -H "Auth-API-Token: ${auth_api_token}" \
         -d "{
           \"value\": \"${cur_pub_addr}\",
           \"ttl\": ${record_ttl},
           \"type\": \"${record_type}\",
           \"name\": \"${record_name}\",
           \"zone_id\": \"${zone_id}\"
         }"
  fi
fi
