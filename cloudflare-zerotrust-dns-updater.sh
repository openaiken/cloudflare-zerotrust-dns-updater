#!/bin/bash
#04 Nov 2023
#requires:
#       curl, jq, bind (or whatever package your distro provides the `dig` command in)
acctID=yourAcctIdHere
token=yourTokenHereWithZeroTrustEditPermissions
domainName=your.domain.name

get_zt_gateway_locations () {
        local response=$(curl -s --request GET \
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
          --url https://api.cloudflare.com/client/v4/accounts/$acctID/gateway/locations/$uuid \
          --header 'Content-Type: application/json' \
          --header "Authorization: Bearer $token" \
          --data "$object")
        local success=$(echo $response | jq -r '.success')
        if [[ "$success" == "true" ]]; then
                echo "success"
                exit 0
        elif [[ "$success" == "false" ]]; then
                echo "failure"
                exit 1
        else
                echo "failure"
                echo "ERROR: Problem with actual API response in HTTP PUT request." >&2
                exit 1
        fi
}

get_current_wan_address () {
        echo $(dig +short $domainName | head -n 1)
}

main () {       
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
                echo "success"
                echo "INFO: IP address configured matches the current DNS/A record for the domain. Exiting." >&2
                exit 0
        fi

        if [[ -z "$locationName" ]] || [[ -z "$locationID" ]] || [[ -z "$newAddress" ]]; then
                echo "failure"
                echo "ERROR: Missing one or more of the location name (\"$locationName\"), location UUID (\"$locationID\"), and/or address (\"$newAddress\")" >&2
                exit 1
        fi

        #assuming these values are now good since they were found, and are non-zero.
        set_zt_gateway_location "$locationName" "$locationID" "$newAddress"
}

main
# :)
