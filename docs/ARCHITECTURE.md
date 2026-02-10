# Architecture

## High-Level Overview

```mermaid
flowchart TB
    subgraph AWS["AWS Region"]
        direction TB
        SRC_DB["Oracle Database<br/>(EC2 / RDS Custom)"]
    end

    subgraph OCI["Oracle Cloud Infrastructure"]
        direction TB

        subgraph VCN["VCN (Private Network)"]
            direction TB

            subgraph PRIV_SUB["Private Subnet"]
                direction TB
                DMS["DMS Service<br/><i>Migration Engine</i>"]
                GG["GoldenGate Deployment<br/><i>CDC + Reverse Replication</i><br/><small>BYOL | Private Endpoint</small>"]
            end

            subgraph ADB_SUB["ADB Private Endpoint"]
                direction TB
                ADB_1["Autonomous DB<br/>(Target 1)"]
                ADB_2["Autonomous DB<br/>(Target N)"]
            end
        end

        subgraph SECURITY["Security & Secrets"]
            direction LR
            VAULT["OCI Vault<br/><i>Passwords & Keys</i>"]
            NSG["NSG<br/><i>Port 1521, 443</i>"]
        end

        subgraph MONITORING["Observability"]
            direction LR
            MON["Monitoring<br/><i>Alarms (W+C)</i>"]
            EVT["Events Service<br/><i>State Changes</i>"]
            LOG["Logging<br/><i>Audit Trail</i>"]
            ONS["Notifications<br/><i>Email/Slack/PD</i>"]
        end

        OBJ["Object Storage<br/><i>Data Pump Staging</i>"]
    end

    SRC_DB -->|"Data Pump<br/>(Initial Load)"| DMS
    SRC_DB <-->|"VPN / FastConnect"| VCN
    DMS -->|"Schema Migration"| ADB_1
    DMS -->|"Schema Migration"| ADB_2
    GG <-->|"CDC Replication"| ADB_1
    GG <-->|"Reverse Replication"| SRC_DB
    DMS -.->|"Staging Files"| OBJ
    DMS -.-> VAULT
    GG -.-> VAULT
    NSG -.->|"Traffic Control"| PRIV_SUB
    MON -->|"Threshold Alerts"| ONS
    EVT -->|"Lifecycle Events"| ONS

    classDef aws fill:#FF9900,stroke:#232F3E,color:#232F3E
    classDef oci fill:#F80000,stroke:#312D2A,color:#fff
    classDef subnet fill:#E8F5E9,stroke:#4CAF50,color:#000
    classDef security fill:#FFF3E0,stroke:#FF9800,color:#000
    classDef monitoring fill:#E3F2FD,stroke:#2196F3,color:#000
    classDef service fill:#fff,stroke:#666,color:#000

    class AWS aws
    class OCI oci
    class PRIV_SUB,ADB_SUB subnet
    class SECURITY security
    class MONITORING monitoring
```

## Data Flow

```mermaid
sequenceDiagram
    participant TF as Terraform
    participant DMS as DMS Service
    participant SRC as Source DB (AWS)
    participant ADB as Target ADB (OCI)
    participant GG as GoldenGate
    participant ONS as Notifications

    rect rgb(240, 248, 255)
        Note over TF,ONS: Phase 1 - Provisioning
        TF->>DMS: Create connections + migration
        TF->>GG: Deploy (private subnet)
        TF->>DMS: Auto-validate (OCI CLI)
        DMS-->>ONS: Validation result event
    end

    rect rgb(240, 255, 240)
        Note over TF,ONS: Phase 2 - Initial Load
        TF->>DMS: Auto-start (if configured)
        DMS->>SRC: Data Pump export
        DMS->>ADB: Data Pump import
        DMS-->>ONS: Migration progress events
    end

    rect rgb(255, 248, 240)
        Note over TF,ONS: Phase 3 - CDC Replication
        DMS->>GG: Enable CDC
        GG->>SRC: Extract (capture changes)
        GG->>ADB: Replicat (apply changes)
        GG-->>ONS: Lag alerts (WARNING/CRITICAL)
    end

    rect rgb(255, 240, 245)
        Note over TF,ONS: Phase 4 - Cutover
        Note over TF: Run pre-cutover script
        TF->>DMS: Verify lag < threshold
        TF->>DMS: Execute switchover
        GG->>ADB: Final apply
        GG->>SRC: Start reverse replication
        DMS-->>ONS: Cutover complete event
    end
```

## Resource Mapping

```mermaid
erDiagram
    SOURCE_DATABASES ||--o{ MIGRATIONS : "referenced by"
    TARGET_DATABASES ||--o{ MIGRATIONS : "referenced by"
    MIGRATIONS ||--|| DMS_SOURCE_CONN : "creates"
    MIGRATIONS ||--|| DMS_TARGET_CONN : "creates"
    MIGRATIONS ||--|| DMS_MIGRATION : "creates"
    SOURCE_DATABASES ||--o| GG_EXT_ORACLE_REG : "creates if GG enabled"
    TARGET_DATABASES ||--o| GG_ADB_REG : "creates if GG enabled"
    GG_DEPLOYMENT ||--o{ GG_ADB_REG : "manages"
    GG_DEPLOYMENT ||--o{ GG_EXT_ORACLE_REG : "manages"
    VAULT_SECRETS ||--|| SOURCE_DATABASES : "stores password"
    VAULT_SECRETS ||--|| TARGET_DATABASES : "stores password"
    MONITORING_ALARMS }o--|| DMS_MIGRATION : "watches"
    MONITORING_ALARMS }o--|| GG_DEPLOYMENT : "watches"
    EVENT_RULES }o--|| NOTIFICATION_TOPIC : "sends to"
```

## Network Topology

```
+------------------------------------------------------------------+
|  OCI VCN (10.0.0.0/16)                                          |
|                                                                  |
|  +---------------------------+   +---------------------------+   |
|  | Private Subnet            |   | Service Gateway           |   |
|  | 10.0.1.0/24               |   | (Oracle Services Network) |   |
|  |                           |   +---------------------------+   |
|  |  +--------+  +--------+  |                                   |
|  |  | DMS    |  | GG     |  |   +---------------------------+   |
|  |  | Conn   |  | Deploy |  |   | NAT Gateway               |   |
|  |  +--------+  +--------+  |   | (Outbound to AWS)          |   |
|  |                           |   +---------------------------+   |
|  |  +--------+  +--------+  |                                   |
|  |  | ADB PE |  | ADB PE |  |   +---------------------------+   |
|  |  | (Prod) |  | (N)    |  |   | DRG / VPN / FastConnect   |   |
|  |  +--------+  +--------+  |   | (AWS Connectivity)         |   |
|  |                           |   +---------------------------+   |
|  |  NSG: 1521, 443 ingress  |                                   |
|  +---------------------------+                                   |
|                                                                  |
+------------------------------------------------------------------+
             |                              |
             | VPN / FastConnect            | Internet (OCI Services)
             v                              v
     +--------------+              +------------------+
     | AWS VPC      |              | Object Storage   |
     | Oracle DB    |              | Vault, ONS, etc. |
     +--------------+              +------------------+
```
