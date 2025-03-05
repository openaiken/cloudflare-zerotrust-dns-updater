# cloudflare-zerotrust-dns-updater
Bash script that uses the Cloudflare API to update the client IP address on your ZT DNS Gateway. 

### What's this
If you use Cloudflare Zero Trust for your upstream DNS, especially the free tier, you may have observed that the Cloudflare Zero Trust Gateway DNS Locations have a client IP address that should be set to your source (your network's WAN/Internet address) in order to benefit from analytics, filtering, and other protections.

Unfortunately, this address is configured statically, and can't be set to use a DNS hostname. I have a working DynamicDNS solution for my WAN address on a domain in my Cloudflare account.

I wrote this script to update that client address in "one click" in the event that my ISP expires my DHCP lease.

The script queries the Cloudflare API to get all the DNS Gateway Locations in Zero Trust, and finds the one configured as default (or the one you specify by name). It then reads the address currently set, queries DNS to see what your domain (presumably on DynDNS) currently resolves to, and compares them. If they are different (i.e. ZT needs to be updated), it queries the Cloudflare API again and sets the DNS Gateway Location network address to the new value from DNS.

The script has some error checking, logs to stderr, and outputs JSON with a simple "success" or "failure" object to stdout upon execution, to facilitate integration into some other automation. Personally I run this script on a Zabbix Server (with stderr directed to /dev/null) so I can easily monitor its routine success/failure.

### Execution
Run the script with `--help` to see the options. If no options are supplied, the script looks for the `.env` file in the script's working directory first, and then in /etc. If options are supplied, the required ones are `--account-id`, `--api-token`, and `--domain`, with the optional ones being `--location-name` (default behavior is to use whatever the "default" location is in Zero Trust) and `--dns-override` (default is Cloudflare's public 1.1.1.1 service).

`stdout` receives a small machine-readable JSON object reporting the execution status. `stderr` receives human-readable messages.

### Notes

- **IMPORTANT**: The $token is **not** your Global API key, it is an API _token_ that must be configured with the permission **Zero Trust: Edit** for your account. [Learn how to make a token here.](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)

- The $acctID is your actual Account ID, not the Zone ID. It's a UUID.

- $domainName is the record for which the A record that needs to be loaded into your CF ZT DNS configuration.

- Only IPv4 is supported, currently.

- This script requires `curl`, `jq`, and whatever package your Linux distro provides the `dig` command in (for Arch it's just `bind`). Otherwise it pretty much uses regular bash syntax.

- This script assumes use of DynDNS to reference your true External/WAN address. If you are using specifically a Cloudflare domain and DynDNS, you'll need to disable Proxy Mode for the record you're updating. If you wish to keep Proxy Mode enabled, then a different method of determining the WAN address (than getting the DNS answer) will be required. You can simply reimplement the `get_current_wan_address()` function in the bash source. One possible approach would be to use the output of `curl ifconfig.me`, where https://ifconfig.me is a free 3rd party utility for this purpose and others.

- Technically the script can be run from anywhere. It doesn't _have_ to be from a host located behind the address you're setting the Cloudflare ZT DNS Location to.
