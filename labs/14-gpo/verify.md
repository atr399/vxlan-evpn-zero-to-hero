# Session 14 - GPO Step-0 Gate (expected: DOC-ONLY on vrnetlab)
    ssh admin@clab-vxlan-evpn-leaf1 'configure terminal ; feature security-group'
Rejected -> confirmed doc-only; record it. Accepted -> apply the config
sketch in docs/future-sessions/SESSION-14-gpo.md, then the decisive test:
two same-VLAN hosts + default-deny contract; if ping STILL passes in
enforced mode, the virtual data plane is not enforcing (doc-only anyway).
