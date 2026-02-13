#!/usr/bin/env python3
"""
Create Oracle GoldenGate checkpoint tables via direct SQL.

Equivalent to AdminClient: ADD CHECKPOINTTABLE <schema.table>
Creates both the main checkpoint table and the auxiliary _lox table.

Supports both thin mode (no client) and thick mode (Oracle Client for NNE).
Automatically detects if thick mode is needed (DPY-3001).

Usage:
  python3 gg_create_checkpoint.py <host> <port> <service_name> <username> <password> <checkpoint_table>

Environment:
  ORACLE_HOME or LD_LIBRARY_PATH - for thick mode (if NNE is enabled on DB)

Exit codes:
  0 = success (tables created or already exist)
  1 = connection or SQL error
"""

import sys
import os


def get_oracle_lib_dir():
    """Find Oracle Client libraries for thick mode."""
    # Check ORACLE_HOME first
    oracle_home = os.environ.get("ORACLE_HOME", "")
    if oracle_home:
        lib_dir = os.path.join(oracle_home, "lib")
        if os.path.exists(os.path.join(lib_dir, "libclntsh.so")):
            return lib_dir

    # Check common Instant Client locations
    for pattern in [
        "/usr/lib/oracle/*/client64/lib",
        "/opt/oracle/instantclient*",
        "/u01/app/oracle/product/*/db_*/lib",
    ]:
        import glob
        matches = sorted(glob.glob(pattern), reverse=True)
        for m in matches:
            if os.path.exists(os.path.join(m, "libclntsh.so")):
                return m

    return None


def connect_db(oracledb, user, password, dsn):
    """Connect to DB, trying thin mode first, then thick mode if NNE."""
    # Try thin mode first (no client needed)
    try:
        conn = oracledb.connect(user=user, password=password, dsn=dsn)
        print("Connected (thin mode)")
        return conn
    except Exception as e:
        err_str = str(e)
        # DPY-3001: NNE requires thick mode
        if "DPY-3001" not in err_str:
            raise

    print("NNE detected (DPY-3001). Switching to thick mode...")
    lib_dir = get_oracle_lib_dir()
    if lib_dir:
        print(f"Using Oracle libraries from: {lib_dir}")
        oracledb.init_oracle_client(lib_dir=lib_dir)
    else:
        # Try without lib_dir (relies on LD_LIBRARY_PATH)
        print("No Oracle lib dir found, trying system LD_LIBRARY_PATH...")
        oracledb.init_oracle_client()

    conn = oracledb.connect(user=user, password=password, dsn=dsn)
    print("Connected (thick mode)")
    return conn


def main():
    if len(sys.argv) != 7:
        print(f"Usage: {sys.argv[0]} <host> <port> <service_name> <user> <password> <checkpoint_table>")
        sys.exit(1)

    host, port, service_name, user, password, checkpoint_table = sys.argv[1:7]
    port = int(port)

    # Parse schema.table
    if "." in checkpoint_table:
        schema, table_name = checkpoint_table.split(".", 1)
    else:
        schema = user
        table_name = checkpoint_table

    lox_table = f"{table_name}_LOX"

    try:
        import oracledb
    except ImportError:
        print("ERROR: oracledb not installed. Run: pip3 install oracledb")
        sys.exit(1)

    dsn = f"{host}:{port}/{service_name}"
    print(f"Connecting to {dsn} as {user}...")

    try:
        conn = connect_db(oracledb, user, password, dsn)
    except Exception as e:
        print(f"ERROR: Connection failed: {e}")
        sys.exit(1)

    cursor = conn.cursor()

    # Main checkpoint table DDL (matches GG 23.26 ADD CHECKPOINTTABLE structure)
    # Key differences from older versions:
    #   - LOG_CMPLT_XIDS (with S) instead of LOG_CMPLT_XID
    #   - LOG_BSN, LOG_XID added in 23.x
    main_ddl = f"""
    CREATE TABLE {schema}.{table_name} (
        GROUP_NAME      VARCHAR2(8)    NOT NULL,
        GROUP_KEY       NUMBER(19)     NOT NULL,
        SEQNO           NUMBER(10),
        RBA             NUMBER(19)     NOT NULL,
        AUDIT_TS        VARCHAR2(29),
        CREATE_TS       DATE           NOT NULL,
        LAST_UPDATE_TS  DATE           NOT NULL,
        CURRENT_DIR     VARCHAR2(255)  NOT NULL,
        LOG_BSN         VARCHAR2(64),
        LOG_CSN         VARCHAR2(64),
        LOG_XID         VARCHAR2(255),
        LOG_CMPLT_CSN   VARCHAR2(64),
        LOG_CMPLT_XIDS  VARCHAR2(255),
        VERSION         VARCHAR2(64),
        PRIMARY KEY (GROUP_NAME, GROUP_KEY)
    )
    """

    # Auxiliary _lox table for transaction overflow
    lox_ddl = f"""
    CREATE TABLE {schema}.{lox_table} (
        GROUP_NAME      VARCHAR2(8)    NOT NULL,
        GROUP_KEY       NUMBER(19)     NOT NULL,
        LOG_CMPLT_CSN   VARCHAR2(64),
        LOG_CMPLT_XIDS  VARCHAR2(255),
        SEQUENCE        NUMBER(19)     NOT NULL,
        PRIMARY KEY (GROUP_NAME, GROUP_KEY, SEQUENCE)
    )
    """

    success = True

    for ddl, tbl in [(main_ddl, f"{schema}.{table_name}"), (lox_ddl, f"{schema}.{lox_table}")]:
        try:
            cursor.execute(ddl)
            conn.commit()
            print(f"OK: Created {tbl}")
        except oracledb.DatabaseError as e:
            error = e.args[0]
            if hasattr(error, 'code') and error.code == 955:
                print(f"OK: {tbl} already exists")
            else:
                print(f"ERROR creating {tbl}: {e}")
                success = False

    cursor.close()
    conn.close()

    if success:
        print(f"Checkpoint table {schema}.{table_name} ready.")
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()