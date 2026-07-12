# Session 16 - Break It (UNTESTED)
1. AS-path check: on extwan, 'show ip bgp 203.0.113.0/24' - path should
   read 65000 65100. Prepend on extinet, watch it propagate through.
2. Filter only ONE direction - traffic blackholes asymmetrically
   (request delivered, reply unroutable). Classic half-filter bug.
3. Default-route both externals into the fabric simultaneously - who
   wins in Tenant-A? (ECMP? best-path?) Predict, then look.
