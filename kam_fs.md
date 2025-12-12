# Distributed SIP Architecture – Kamailio + FreeSWITCH + PostgreSQL HA

## Overview

This platform provides a scalable and resilient SIP infrastructure built around:

- **Kamailio** as the SIP edge/load balancer/registrar  
- **FreeSWITCH Cluster** as the media and call-processing layer  
- **PostgreSQL HA Cluster** as the centralized backend database for configuration, routing data, and CDRs  

The design supports high throughput, horizontal scaling, graceful failover, and a unified data layer.

---

## System Architecture Diagram


                      ┌────────────────────────────┐
                      │        Internet / SIP       │
                      │        Carriers / PBXs      │
                      └──────────────┬──────────────┘
                                     │
                             (Public SIP Traffic)
                                     │
                       ┌─────────────▼─────────────┐
                       │         Kamailio LB       │
                       │   (SIP Proxy / Registrar) │
                       │   - PostgreSQL backend    │
                       │   - Load Balancing        │
                       └─────────────┬─────────────┘
                                     │
                       (dispatcher load balancing)
             ┌──────────────┬──────────────┬──────────────┐
             │              │              │               │
   ┌─────────▼────────┐┌────▼──────────┐┌────▼──────────┐┌────▼──────────┐
   │  FreeSWITCH #1   ││ FreeSWITCH #2  ││ FreeSWITCH #3  ││ FreeSWITCH #N │
   │ - RTP/Audio      ││ - RTP/Audio    ││ - RTP/Audio    ││ - RTP/Audio    │
   │ - Dialplan       ││ - Dialplan     ││ - Dialplan     ││ - Dialplan     │
   └─────────┬────────┘└────┬───────────┘└────┬───────────┘└────┬───────────┘
             │               │                │                │
             └───────────────┬────────────────┴────────────────┬───────────────┘
                             │ (Events / CDR / Metrics)
                             ▼
               ┌───────────────────────────────────────────────┐
               │             Backend Services Tier             │
               │  • PostgreSQL HA Cluster (Patroni/Etcd)       │
               │                                               │
               │                                               │
               │                                               │
               └───────────────────────────────────────────────┘








## 1. Kamailio – SIP Proxy / Registrar / Load Balancer

Kamailio acts as the central entry point for all SIP traffic. It performs registration, authentication, NAT mediation, SIP routing, and load balancing to the FreeSWITCH cluster.

### Core Responsibilities

### **SIP Load Balancer**
Efficiently distributes inbound SIP calls to FreeSWITCH nodes.

### **Registrar Server**
Stores SIP user bindings in PostgreSQL.

### **Routing Engine**
Performs dynamic routing based on dialplan rules, user location, and dispatcher groups.

### **User Authentication**
Digest authentication backed by PostgreSQL.

### **Failover Control**
Detects failed FreeSWITCH nodes via SIP OPTIONS probing.

---

## Load-Balancing Algorithms (dispatcher module)

Kamailio supports several LB modes:

- **round-robin** – simple sequential distribution  
- **hash over Call-ID** – call stickiness for multi-dialog sessions  
- **weight-based** – distribute based on node capacity  
- **active-failover** – send calls to primary node until down, then failover  

---

## Example Kamailio Configuration (dispatcher)

```cfg
modparam("dispatcher", "db_url", "postgres://kam:pw@pg1/kamailio")
modparam("dispatcher", "ds_ping_interval", 10)
modparam("dispatcher", "ds_probing_mode", 1)
modparam("dispatcher", "ds_ping_method", "OPTIONS")


These settings enable:

PostgreSQL-backed dispatcher lists

Active node probing every 10 seconds

Automatic failover on OPTIONS timeout



2. FreeSWITCH Node Cluster (Media Layer)

Each FreeSWITCH instance provides all media-plane responsibilities and handles call processing logic.

Responsibilities of each FS node

RTP/Audio handling (media relay, SRTP, codecs)

Dialplan execution

IVR / Voicemail

Transcoding (G.711/G.729/Opus/etc.)

Conferencing

ESL (Event Socket Library) integration

Call routing logic

CDR generation (to PostgreSQL, files, or via ESL)

Scaling

Nodes are fully stateless from a SIP perspective thanks to Kamailio.
Add/remove nodes by updating the dispatcher table in PostgreSQL.

3. PostgreSQL HA Cluster
Technologies

Patroni – cluster management / failover

Etcd – distributed consensus

PgBouncer / HAProxy (optional) for connection pooling

Functions

Central database for:

Kamailio subscriber and location data

Dispatcher tables

Routing rules

CDR records

FreeSWITCH event logs, metrics

Benefits

Automatic failover

Zero-downtime maintenance

Consistent configuration across nodes

Data & Event Flows
Inbound Call Flow

SIP INVITE hits Kamailio

Kamailio authenticates + applies routing rules

Dispatcher selects FreeSWITCH node

INVITE relayed to chosen FS instance

FreeSWITCH handles RTP/media and executes dialplan

CDRs + events are sent to PostgreSQL backend

Registration Flow

REGISTER from SIP phone

Kamailio checks PostgreSQL for user credentials

Saves contact binding

Used later for routing inbound INVITEs

Advantages of This Architecture
Scalability

Horizontal expansion of FreeSWITCH nodes

Stateless SIP proxy layer

Dispatcher-based load balancing

Resilience

Automatic Kamailio failover of FS nodes

PostgreSQL HA ensures uptime of data layer

Optional active/standby Kamailio pair

Performance

Kamailio can handle tens of thousands of CPS

FreeSWITCH nodes isolated for media workload

Operational Flexibility

Centralized configuration

Unified CDR/data storage

Real-time monitoring via ESL