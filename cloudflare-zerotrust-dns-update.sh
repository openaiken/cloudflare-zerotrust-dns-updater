#!/bin/bash
# 05 Mar 2025
# https://github.com/openaiken/cloudflare-zerotrust-dns-updater
# requires: curl, jq, bind (i.e. whatever package your distro packages the dig command in)

# All domain resolutions in this script are performed by an independent DNS server, specified by this variable,
# because the user's system DNS resolution may be impacted directly or indirectly by the CF ZT DNS Gateway address
# being out of date, which is what this script addresses. This prevents a catch-22.
# Default DNS server (can be overridden via CLI or env file)
DNS_SERVICE=1.1.1.1
# This is the filename of the environment file. Its presence is checked for in the working directory and then in /etc.
ENV_FILENAME="cloudflare_zerotrust_dns_update.env"

# Print a Machine-Readable (JSON) object to stdout showing the execution status
print_execution_status () {
  # Was the API call successful or not?
  local successful=$1 # success|failure
  # Did the address configured in Cloudflare ZT match the DNS record?
  local matches=$2    # true|false
  # Was there an issue with the execution of this script?
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
  # The file is checked for in the current directory first, which is the dir containing this script. Then /etc is checked.
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

# Validate initialization of required parameters
if [[ -z "$acctID" || -z "$token" || -z "$domainName" ]]; then
  print_execution_status "failure" false true
  echo "ERROR: Missing required parameters. --account-id, --api-token, and --domain are required." >&2
  show_help
  exit 1
fi

# Determine the Cloudflare API endpoint's IP address using the (possibly overridden) independent DNS server.
API_ENDPOINT=$(dig @"$DNS_SERVICE" +short api.cloudflare.com | paste -sd, -)

# Get a JSON list of all of the Zero Trust DNS Locations on the Cloudflare Account
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
  # We have to prepare a JSON object to post to the API containing the changes we're making to the DNS location.
  local object
  object=$(jq -M -n --arg k1 "$name" --arg k2 "$addr/32" \
    '{ "name": $k1, "networks": [ {"network": $k2} ] }')
  # HTTP PUT to the API and store the JSON response 
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
    # The API call was successful, the addresses did not match, and there was no execution issue. Perfect.
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

# Get the IP address that the DNS Gateway's Source IP Address will be checked against, and set to, if needed.
get_current_wan_address () {
  # This is a simple DNS lookup, and it uses the first result, just in case there are multiple.
  # A future enhancement could be support for an option to get the value returned from curling https://ifconfig.me.
  dig @"$DNS_SERVICE" +short "$domainName" | head -n 1
}

main () {
  # Ensure the API endpoint we resolved looks somewhat like an IPv4 address.
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
  # Iterate through the Locations list, looking for the one we want to set.
  for (( i=0; i<listLength; i++ )); do
    local rawLocation
    rawLocation=$(echo "$locationList" | jq ".result[$i]")
    # If the Location Name variable was set, check for a matching name. Else, check for the location set as Default.
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
    # The API call was successful, and the addresses matched, so no action required. Perfect.
    print_execution_status "success" true false
    echo "INFO: IP address configured matches the current DNS/A record for the domain. Exiting." >&2
    exit 0
  fi

  if [[ -z "$locName" || -z "$locationID" || -z "$newAddress" ]]; then
    # If for any reason, the location name/ID haven't been figured out, or there was an issue getting the new address, exit now.
    print_execution_status "failure" false true
    echo "ERROR: Missing one or more of the location name (\"$locName\"), location UUID (\"$locationID\"), and/or address (\"$newAddress\")" >&2
    exit 1
  fi

  # The script exits before this point if the location's source address doesn't need to be updated.
  set_zt_gateway_location "$locName" "$locationID" "$newAddress"
}

main
# :)
