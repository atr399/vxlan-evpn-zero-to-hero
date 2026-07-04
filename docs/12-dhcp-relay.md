# Session 12: DHCP Relay in the Overlay — Teaching Guide

**Estimated duration**: 35-45 min

**Goals to land**:
1. Why distributed anycast gateway makes DHCP *harder*, not easier
2. The unique-per-VRF-loopback giaddr — and why it can't be the anycast IP
3. Option 82: link-selection picks the scope, vpn sub-option picks the tenant
4. The four-way triage of "no DHCP" using the server log

**The "wow" moment**: a host with no IP runs one `udhcpc` command and
comes up fully addressed, correct subnet, correct gateway — and then you
show the server log proving the giaddr was the leaf's *unique* loopback,
not the anycast gateway every leaf shares. The anycast gateway that made
forwarding beautiful is exactly what would have broken this, and the
loopback is the fix.

**Real production value**: this is the first *service* the fabric
offers, and in a real build it's urgent — server teams can't PXE-boot or
image bare metal until relay works. Every production EVPN fabric runs it.

---

## Pre-call checklist

- [ ] Lab deployed with the Session 12 topology (Session 9 base + DHCP
      server host) — see docs/DEPLOYMENT.md "Model B"
- [ ] `switch.sh 12-dhcp-relay` applied; dnsmasq running on the server
- [ ] You've run `verify.md` end-to-end and gotten a clean lease
- [ ] Have the server log tailing in a spare pane —
      `docker exec clab-vxlan-evpn-dhcp-server sh -c 'logread -f | grep -i dhcp'`
- [ ] break-it.md open — break-it #2 (loopback-in-scope) is the gem

---

## Opening (~3 min)

> "Every host we've used so far had a static IP we typed in by hand.
> Real data centers don't work that way — servers, VMs, PXE-booting bare
> metal, all of it gets its address from DHCP. So today we make the
> fabric hand out addresses."

> "Sounds routine. It isn't — and the reason is the anycast gateway we
> were so proud of in Session 4."

> "Remember what made anycast great: every leaf owns the *same* gateway
> IP, 10.100.10.1, and any leaf will answer for it. Fantastic for
> forwarding — the gateway is always one hop away."

> "Now think about DHCP. A client broadcasts 'I need an address.' Its
> local leaf relays that to the server. The server sends an address
> back — to the relay. But the relay's IP is... 10.100.10.1. The same
> IP on *every* leaf. The server's reply could come back to any of
> them. And which subnet does 10.100.10.1 even mean, when every VLAN's
> gateway uses the same anycast scheme?"

> "The thing that made anycast beautiful for forwarding just broke the
> control protocol. That's the lesson of today, and it shows up again
> and again on anycast fabrics: *anything that needs to reply to one
> specific box has a problem when every box shares an address.*"

> "The fix is elegant — give each leaf a second, unique address just for
> DHCP, and use Option 82 to tell the server the real subnet and tenant.
> Let's build it."

---

## Beat-by-beat demo

### Beat 1: The problem, made concrete (2 min)

On leaf1:

```
show running-config interface Vlan10
```

> "There's our anycast gateway — 10.100.10.1, same on every leaf. If we
> naively relayed DHCP from this, the server would stamp 10.100.10.1 as
> the relay address and have no idea which leaf or which subnet. Watch
> what we did instead."

Point at the two relay lines:

> "`ip dhcp relay address` — that's *where the server is*. And
> `ip dhcp relay source-interface loopback99` — that's the fix. We
> source the relay from a *unique* loopback, not the anycast IP."

### Beat 2: The unique loopback (2 min)

```
show running-config interface loopback99
```

> "loopback99, in VRF Tenant-A, 10.99.0.21 — and on leaf2 it's
> 10.99.0.22. **Unique per leaf.** This is the giaddr the server will
> reply to. Because it's unique, the reply comes back to *this exact
> leaf*, not 'whichever leaf the anycast IP happened to land on.'"

```
show bgp l2vpn evpn | include 10.99.0.21
```

> "And it's advertised into the tenant VRF, so the server's reply can
> actually route back across the fabric to find it. Forward path and
> return path both work."

### Beat 3: The lease — the payoff (3 min)

Have the server-log pane visible. Then:

```bash
docker exec clab-vxlan-evpn-host1 sh -c 'ip addr flush dev eth1; udhcpc -i eth1 -n'
docker exec clab-vxlan-evpn-host1 ip addr show eth1
```

> "No IP a second ago. Now — 10.100.10.137, in VLAN 10's scope, default
> route via the anycast gateway. One command, fully addressed."

Point at the server log pane:

> "Watch the log. DISCOVER, OFFER, REQUEST, ACK — the DORA exchange. And
> look at the giaddr field: **10.99.0.21**. The leaf's unique loopback,
> NOT 10.100.10.1. The server replied to *this leaf specifically*. The
> anycast IP never entered the DHCP conversation."

### Beat 4: How the server picked the right subnet (3 min)

> "Here's the subtle part. The giaddr is 10.99.0.21 — that's a
> 10.99.x address. But the client got a 10.100.10.x address. How did the
> server know to use the VLAN 10 scope when the giaddr is in a totally
> different subnet?"

*(let them think)*

> "Option 82, link-selection sub-option. The relay told the server two
> *separate* things: 'reply to me at 10.99.0.21' (giaddr, reachability)
> and 'but the client is actually in 10.100.10.0/24' (link-selection,
> scope). The classic single-router world fused those — giaddr was both.
> On an anycast fabric they *have* to be split."

> "And there's a vpn sub-option too, carrying the VRF name. We have one
> tenant today, but the moment you have two tenants with overlapping
> 10.100.10.0/24, that sub-option is how one DHCP server keeps them
> straight."

### Beat 5: Break it live — the loopback-in-scope trap (4 min)

This is the memorable one.

> "Let me show you the mistake everyone makes once. I'll move the relay
> loopback *inside* the pool the server hands out."

On leaf1:

```
configure terminal
interface loopback99
  ip address 10.100.10.150/32
end
```

> "Now the giaddr is 10.100.10.150 — which is *inside* the
> 10.100.10.100-200 scope. Watch what happens over a few leases."

```bash
docker exec clab-vxlan-evpn-host1 sh -c 'ip addr flush dev eth1; udhcpc -i eth1 -n'
# and again
docker exec clab-vxlan-evpn-host1 sh -c 'ip addr flush dev eth1; udhcpc -i eth1 -n'
```

> "Intermittent. Sometimes fine, sometimes the server tries to hand out
> .150 — which the leaf is *also* using as its giaddr. Two things own
> one address. The failure is intermittent and points everywhere except
> the real cause."

> "This is why production keeps relay loopbacks in their own block —
> 10.99.0.0/24 here — provably outside every client scope. **Rule:
> infrastructure addresses never overlap pools.** When DHCP fails
> *intermittently* rather than totally, suspect an address overlap
> first."

Restore:

```
interface loopback99
  ip address 10.99.0.21/32
end
```

### Beat 6: The triage table (3 min)

> "Here's the thing that makes you good at this in production. 'The host
> didn't get an address' has *four* different causes, and they look
> identical from the host. The server log tells them apart."

Walk the table from break-it.md:

> - "**Nothing in the server log at all?** The relay address is missing
>   or wrong — the discover never left the leaf. Forward-path problem."
> - "**Discover and offer logged, but the host gets nothing?** The reply
>   can't route back to the giaddr — the relay loopback isn't advertised
>   into the VRF. Return-path problem."
> - "**Host gets an address, but in the wrong subnet?** The server is
>   keying scope on giaddr instead of link-selection. Option 82 problem."
> - "**Intermittent?** Address overlap — giaddr inside a pool."

> "Four symptoms, four fixes, one diagnostic: the server log. That
> triage *is* the production skill."

---

## Common questions and good answers

**Q: "Why not just put the DHCP server on every subnet locally?"**

> "You could, but then you're running DHCP scopes on hundreds of leaves
> and your IPAM is scattered everywhere. Centralized DHCP reached by
> relay is how real shops do it — one source of truth, relay carries the
> requests in. The relay is what makes centralization possible across an
> anycast fabric."

**Q: "Does the anycast gateway IP ever get used in DHCP at all?"**

> "Only as the gateway the client *receives* in its lease — Option 3,
> default router, 10.100.10.1. That's correct: the client should use the
> anycast gateway for forwarding. But the relay *conversation* with the
> server uses the unique loopback. Anycast for data plane, loopback for
> the DHCP control exchange — two addresses, two jobs."

**Q: "What if I have the same subnet in two VRFs?"**

> "That's exactly what the Option 82 vpn sub-option is for. The relay
> stamps the VRF identity, the server has per-tenant scopes, and
> overlapping 10.100.10.0/24 in Tenant-A and Tenant-B get separate
> pools. Without that sub-option, one DHCP server can't serve
> overlapping tenants — you'd need a server per VRF."

**Q: "Is dnsmasq what I'd use in production?"**

> "No — you'd use Infoblox, Windows DHCP, or ISC Kea with your IPAM. But
> the relay protocol is identical. The leaf config doesn't change one
> line whether the server is dnsmasq in a container or a million-dollar
> IPAM appliance. dnsmasq just has to be Option-82-aware, which it is."

**Q: "How does this interact with vPC?"**

> "On a vPC pair, both leaves share the anycast gateway but each still
> needs its *own* unique relay loopback, and the loopback has to be
> advertised so replies route correctly even after a peer failover.
> Cisco's guide calls out a per-vPC-VTEP loopback specifically. Same
> principle, one extra wrinkle."

---

## Cut points

- **Trim Beat 4** (Option 82 detail) to 90 seconds if the audience isn't
  deep on DHCP internals — the giaddr-vs-link-selection split is the one
  idea to keep.
- **Beat 6** (triage table) can be a handout instead of a walk-through if
  short on time.

Do NOT cut Beat 5 (the live loopback-in-scope break). It's the
memorable, production-real mistake — the thing they'll actually hit.

---

## Closing the call

> "Today the fabric started offering a real service. Hosts get addresses
> the way they do in production — DHCP, centrally, across the fabric."

> "Key takeaways:"
> 1. "Anycast gateway is a forwarding feature that fights any protocol
>     needing to reply to one specific leaf. DHCP is the first one you
>     hit."
> 2. "The fix: a unique per-VRF loopback as giaddr — never the anycast
>     IP — advertised into the tenant VRF."
> 3. "Option 82 splits the job: link-selection picks the subnet, the vpn
>     sub-option picks the tenant; giaddr is just reachability."
> 4. "'No DHCP' has four causes; the server log tells you which."

> "That last point is the one that'll save you at 2 AM. Most people
> stare at the client. The answer is always in the server log."

---

## Notes for me

1. **This session exists because of a question a student will always
   ask in Session 4:** "wait, if every leaf has the same gateway IP, how
   does DHCP work?" I used to hand-wave it. Now it's a whole session,
   and it's one of the more satisfying ones because the anycast
   'problem' and its loopback 'fix' are so clean.

2. **The build's real gotcha was the relay loopback subnet.** First pass
   I put it in 10.100.x by habit and got intermittent failures — which
   became break-it #2. The lab teaches the exact mistake I made.

3. **dnsmasq's `dhcp-relay` + tag-based ranges** are how you fake
   link-selection scope selection without a real IPAM. If dnsmasq ever
   behaves oddly, check it's built with the DHCP option compiled in
   (Alpine's package is) and that `port=0` is set (disables its DNS,
   which we don't want here).

4. **Keep the server-log pane visible the whole session.** Every beat
   and every break-it is read from that log. It's the star of the show —
   the triage lesson only lands if they watch the log react in real time.

5. **vPC interaction is real but I keep it to the Q&A** — full vPC-relay
   detail (per-VTEP loopback, advertise after failover) is a rabbit hole
   that distracts from the core anycast-vs-DHCP idea. Mention, don't
   demo, unless asked.
