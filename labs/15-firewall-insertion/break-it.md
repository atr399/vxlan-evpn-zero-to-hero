# Session 15 - Break It (UNTESTED predictions)
1. Kill the fw container (docker stop). Both tenants isolated again -
   the fw is a single point of failure. Discuss: production = fw PAIRS
   + service leaf pairs (Option B in the doc).
2. Remove the ct/established rule - forward ping works, replies dropped.
   One-way-audible telephone. Stateful vs stateless in one rule.
3. Re-add the 05b RT leak WHILE the sandwich is up - which path wins?
   (Leaked EVPN route vs static: compare admin distances, predict, test.)
4. Set fw eth1 down only - watch leaf1's static route: does it stay in
   the RIB (static to a dead next-hop = blackhole) vs what track/IP-SLA
   would fix. Motivates ePBR/probes (verified ABSENT on this platform -
   the gap is the lesson).
