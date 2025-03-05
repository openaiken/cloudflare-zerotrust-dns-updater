#!/bin/bash
#04 Nov 2023
#requires:
#	curl jq

DNS_SERVICE="1.1.1.1"
API_ENDPOINT=$(dig @"$DNS_SERVICE" +short api.cloudflare.com | paste -sd, -)

print_execution_status () {
	local successful=$1 #success|failure
	local matches=$2 #true|false
	local execIssue=$3 #true|false
	echo "{\"successful\": \"$successful\", \"matches\": $matches, \"execIssue\": $execIssue}"
	#
	#statement below hard coded for testing purposes
	#	
	#echo "{\"successful\": \"success\", \"matches\": false, \"execIssue\": false}"
}

get_zt_gateway_locations () {
	local response=$(curl -s --request GET \
	  --resolve +api.cloudflare.com:443:$API_ENDPOINT \
	  --connect-timeout 3 \
	  --max-time 22 \
	  --url https://api.cloudflare.com/client/v4/accounts/$acctID/gateway/locations \
	  --header "Content-Type: application/json" \
	  --header "Authorization: Bearer $token")
	echo "$response"
}

set_zt_gateway_location () {
	local name=$1
	local uuid=$2
	local addr=$3
	local object=$(jq -M -n --arg k1 true --arg k2 "$name" --arg k3 "$addr/32" '{ "client_default": true, "name": $k2, "networks": [ {"network": $k3} ]}')
	local response=$(curl -s --request PUT \
	  --resolve +api.cloudflare.com:443:$API_ENDPOINT \
	  --connect-timeout 3 \
	  --max-time 22 \
	  --url https://api.cloudflare.com/client/v4/accounts/$acctID/gateway/locations/$uuid \
	  --header 'Content-Type: application/json' \
	  --header "Authorization: Bearer $token" \
	  --data "$object")
	local success=$(echo $response | jq -r '.success')
	if [[ "$success" == "true" ]]; then
		print_execution_status "success" false false
		exit 0
	elif [[ "$success" == "false" ]]; then
		print_execution_status "failure" false false
		exit 1
	else
		print_execution_status "failure" false true
		echo "ERROR: Problem with actual API response in HTTP PUT request." >&2
		exit 1
	fi
}

get_current_wan_address () {
	echo $(dig @"$DNS_SERVICE" +short $domainName | head -n 1)
}

main () {
	#taking input from arguments so we can control where the API secrets come from
	acctID=$1
	token=$2
	domainName=$3
	
	if [[ ! $API_ENDPOINT =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(,[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)*$ ]]; then
		print_execution_status "failure" false true
		echo "ERROR: Didn't resolve the Cloudflare API endpoint to an IP address; got: $API_ENDPOINT . Exiting." >&2
		exit 1
	fi

	local locationList=$(get_zt_gateway_locations)
	local listLength=$(echo $locationList | jq '.result[].id' | wc -l)
	for (( i=0 ; i<$listLength ; i++ )); do
		local rawLocation=$(echo $locationList | jq ".result[$i]")
		local isDefault=$(echo $rawLocation | jq '.client_default')
		if [[ "$isDefault" == "true" ]]; then
			local locationName=$(echo $rawLocation | jq '.name' | grep -o '[^"]*')
			local locationID=$(echo $rawLocation | jq '.id' | grep -o '[^"]*')
			break
		fi
	done
	
	#rawLocation is still assigned the "default" location object, since the loop broke after iterating to it.
	local oldAddress=$(echo $rawLocation | jq -r ".networks[0].network" | grep -o '[^"]*')
	local newAddress=$(get_current_wan_address)

	if [[ "$newAddress/32" == "$oldAddress" ]]; then
		print_execution_status "success" true false
		echo "INFO: IP address configured matches the current DNS/A record for the domain. Exiting." >&2
		exit 0
	fi

	if [[ -z "$locationName" ]] || [[ -z "$locationID" ]] || [[ -z "$newAddress" ]]; then
		print_execution_status "failure" false true
		echo "ERROR: Missing one or more of the location name (\"$locationName\"), location UUID (\"$locationID\"), and/or address (\"$newAddress\")" >&2
		exit 1
	fi

	#assuming these values are now good since they were found, and are non-zero.
	set_zt_gateway_location "$locationName" "$locationID" "$newAddress"
}

main "$@"
# :)
