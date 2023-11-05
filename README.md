# cloudflare-zerotrust-dns-updater

### What's this
If you use Cloudflare Zero Trust for your upstream DNS, especially the free tier, you may have observed that the Cloudflare Zero Trust Gateway DNS Locations have a client IP address that should be set to your source (your network's WAN/Internet address) in order to benefit from analytics, filtering, and other protections.

Unfortunately, this address is configured statically, and can't be set to use a DNS hostname. I have a working DynamicDNS solution for my WAN address on a domain in my Cloudflare account.

I wrote this script to update that client address in "one click" in the event that my ISP expires my DHCP lease.

The script queries the Cloudflare API to get all the DNS Gateway Locations in Zero Trust, and finds the one configured as default. It then reads the address currently set, queries DNS to see what your domain (presumably on DynDNS) currently resolves to, and compares them. If they are different (i.e. ZT needs to be updates), it queries the Cloudflare API again and sets the DNS Gateway Location network address to the new value.

The script has some error checking, logs to stderr, and outputs a simple "success" or "failure" to stdout upon execution, to facilitate integration into some other automation.
