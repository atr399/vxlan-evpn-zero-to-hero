# Session 13 - Break It (UNTESTED)
1. Mismatch the ESI: change leaf2 to ethernet-segment 2002. Predict: two
   independent single-homed segments; DF election vanishes; possible
   duplicate BUM to host1. Verify with route-type 4 + broadcast ping.
2. Kill the DF's host link (shut Eth1/3 on whichever leaf is DF).
   Predict: Type-1 mass-withdrawal repoints remote leaves in <1s;
   compare failover ping loss vs Session 6 vPC.
3. Re-add the vPC secondary VIP (10.0.1.100) while ESI is up. Predict:
   conflicting advertisement model; observe which next-hop remote
   leaves prefer. Then remove it again.
