#!/bin/bash
# 05 Mar 2025
# https://github.com/openaiken/cloudflare-zerotrust-dns-updater
# requires: curl, jq, bind (i.e. whatever package your distro packages the dig command in)

# Default DNS server (can be overridden via CLI or env file)
DNS_SERVICE=1.1.1.1
ENV_FILENAME="cloudflare_zerotrust_dns_update.env"

print_execution_status () {
  local successful=$1 # success|failure
  local matches=$2    # true|false
  local execIssue=$3  # true|false
  echo "{\"successful\": \"$successful\", \"matches\": $matches, \"execIssue\": $execIssue}"
}

# Display the help menu
show_help() {
  cat <<EOF >&2
Usage: $0 [OPTIONS]

Options:
  --account-id      Cloudflare Account ID (required)
  --api-token       Cloudflare API Token (required)
  --domain          Domain name for DNS lookup (required)
  --location-name   DNS Gateway Location name to update (optional, defaults to whatever is the Default Location on your account; use 'single quotes')
  --dns-override    DNS server for dig (optional, default: $DNS_SERVICE)
  --help            Display this help message

If no options are provided, the script will try to load environment variables from '$ENV_FILENAME'.
EOF
}

# If CLI arguments are provided, use them; otherwise, load from environment file.
if [[ $# -gt 0 ]]; then
  # Parse CLI options
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --account-id)
        acctID="$2"
        shift 2
        ;;
      --api-token)
        token="$2"
        shift 2
        ;;
      --domain)
        domainName="$2"
        shift 2
        ;;
      --location-name)
        locationName="$2"
        shift 2
        ;;
      --dns-override)
        DNS_SERVICE="$2"
        shift 2
        ;;
      --help)
        show_help
        exit 0
        ;;
      *)
        echo "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done
else
  if [[ -f "./$ENV_FILENAME" ]]; then
    source "./$ENV_FILENAME"
  elif [[ -f "/etc/$ENV_FILENAME" ]]; then
    source "/etc/$ENV_FILENAME"
  else
    print_execution_status "failure" false true
    echo "ERROR: No CLI arguments provided and environment file '$ENV_FILENAME' not found." >&2
    show_help
    exit 1
  fi
fi

# Validate required parameters
if [[ -z "$acctID" || -z "$token" || -z "$domainName" ]]; then
  print_execution_status "failure" false true
  echo "ERROR: Missing required parameters. --account-id, --api-token, and --domain are required." >&2
  show_help
  exit 1
fi

# Determine the Cloudflare API endpoint using the (possibly overridden) DNS server.
API_ENDPOINT=$(dig @"$DNS_SERVICE" +short api.cloudflare.com | paste -sd, -)

get_zt_gateway_locations () {
  local response
  response=$(curl -s --request GET \
    --resolve +api.cloudflare.com:443:"$API_ENDPOINT" \
    --connect-timeout 3 \
    --max-time 22 \
    --url "https://api.cloudflare.com/client/v4/accounts/$acctID/gateway/locations" \
    --header "Content-Type: application/json" \
    --header "Authorization: Bearer $token")
  echo "$response"
}

set_zt_gateway_location () {
  local name=$1
  local uuid=$2
  local addr=$3
  local object
  object=$(jq -M -n --arg k1 true --arg k2 "$name" --arg k3 "$addr/32" \
    '{ "client_default": true, "name": $k2, "networks": [ {"network": $k3} ] }')
  local response
  response=$(curl -s --request PUT \
    --resolve +api.cloudflare.com:443:"$API_ENDPOINT" \
    --connect-timeout 3 \
    --max-time 22 \
    --url "https://api.cloudflare.com/client/v4/accounts/$acctID/gateway/locations/$uuid" \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" \
    --data "$object")
  local success
  success=$(echo "$response" | jq -r '.success')
  if [[ "$success" == "true" ]]; then
    print_execution_status "success" false false
    exit 0
  elif [[ "$success" == "false" ]]; then
    print_execution_status "failure" false false
		echo "ERROR: API call failed. Here's the full response:" >&2
		echo "$response" | jq `.` >&2
    exit 1
  else
    print_execution_status "failure" false true
    echo "ERROR: Problem with actual API response in HTTP PUT request." >&2
    exit 1
  fi
}

get_current_wan_address () {
  dig @"$DNS_SERVICE" +short "$domainName" | head -n 1
}

main () {
  if [[ ! $API_ENDPOINT =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(,[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)*$ ]]; then
    print_execution_status "failure" false true
    echo "ERROR: Didn't resolve the Cloudflare API endpoint to an IP address; got: $API_ENDPOINT . Exiting." >&2
    exit 1
  fi

  local locationList
  locationList=$(get_zt_gateway_locations)
  local selectedLocation=""
  local listLength
  listLength=$(echo "$locationList" | jq '.result | length')
  for (( i=0; i<listLength; i++ )); do
    local rawLocation
    rawLocation=$(echo "$locationList" | jq ".result[$i]")
    if [[ -n "$locationName" ]]; then
      local currentName
      currentName=$(echo "$rawLocation" | jq -r '.name')
      if [[ "$currentName" == "$locationName" ]]; then
        selectedLocation="$rawLocation"
        break
      fi
    else
      local isDefault
      isDefault=$(echo "$rawLocation" | jq -r '.client_default')
      if [[ "$isDefault" == "true" ]]; then
        selectedLocation="$rawLocation"
        break
      fi
    fi
  done

  if [[ -z "$selectedLocation" ]]; then
    print_execution_status "failure" false true
    echo "ERROR: Could not find a matching location." >&2
    exit 1
  fi

  local locName
  locName=$(echo "$selectedLocation" | jq -r '.name')
  local locationID
  locationID=$(echo "$selectedLocation" | jq -r '.id')
  local oldAddress
  oldAddress=$(echo "$selectedLocation" | jq -r ".networks[0].network")
  local newAddress
  newAddress=$(get_current_wan_address)

  if [[ "$newAddress/32" == "$oldAddress" ]]; then
    print_execution_status "success" true false
    echo "INFO: IP address configured matches the current DNS/A record for the domain. Exiting." >&2
    exit 0
  fi

  if [[ -z "$locName" || -z "$locationID" || -z "$newAddress" ]]; then
    print_execution_status "failure" false true
    echo "ERROR: Missing one or more of the location name (\"$locName\"), location UUID (\"$locationID\"), and/or address (\"$newAddress\")" >&2
    exit 1
  fi

  set_zt_gateway_location "$locName" "$locationID" "$newAddress"
}

main
# :)
