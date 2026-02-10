#!/usr/bin/env bash

########################################################################################################################
## Copyright (c) 2023 Oracle and/or its affiliates.  All rights reserved.
## Licensed under the Universal Permissive License v 1.0 as shown at http://oss.oracle.com/licenses/upl.
##
##  File name    :  dms-db-prep-v2.sh
##  Description  :  Data Migration Service script to provide sql instructions to prepare
##                  your source/target database for a migration.
##  Call Syntax  :  ./dms-db-prep-v2.sh
##                  Run the script and preparation parameters will be asked on the march.
##  Requirements :  Make sure the file have execution permissions granted.
##                  Ensure that the Bash shell level used is 4.4 or higher.
##  Last modified:  01 Jul 2025
########################################################################################################################

_mainScript_() {
    # Clean up
    _cleanupSqlScript_

    # Ask for the parameters to form the SQL Script
    _readPrepMigrationParams_
    echo 

    # Generate sql script
    _dbPrepSqlScript_

    # Present further instructions
    _runSqlScriptInstructions_

}
# end _mainScript_


# ################################## Flags and defaults
# Required variables
LOGFILE="${HOME}/logs/$(basename "$0").log"
LOGLEVEL=ERROR

# Migration information
DBTYPE=source
DBTENANT=s #single
MIGTYPE=online
PDBSERVICENAME=
INITIALLOADUSR=system
INITIALLOADPWD=dummy
GGADMINPWD=dummy
ISONLINEMIG=YES
ISTGTDB=NO
ISRDS=NO
ISMULTITENANT=NO
ISADB=NO
PDBREPLICATIONUSR=ggadmin
CDBREPLICATIONUSR=c##ggadmin

# Kind of databases according to migration types
SRC_OFFLINE_NONPDB=src-offline-nonPDB
SRC_OFFLINE_NONPDB_RDS=src-offline-nonPDB-RDS
SRC_OFFLINE_PDB=src-offline-PDB
SRC_OFFLINE_ADB=src-offline-ADB
SRC_ONLINE_NONPDB=src-online-nonPDB
SRC_ONLINE_NONPDB_RDS=src-online-nonPDB-RDS
SRC_ONLINE_PDB=src-online-PDB
SRC_ONLINE_ADB=src-online-ADB
TGT_OFFLINE_ATP=tgt-offline-ATP
TGT_ONLINE_ATP=tgt-online-ATP
TGT_ONLINE_NON_PDB=tgt-online-nonPDB
TGT_ONLINE_PDB=tgt-online-PDB
TGT_OFFLINE_NON_PDB=tgt-offline-nonPDB
TGT_OFFLINE_PDB=tgt-offline-PDB
SCRIPTTYPE=none

# output sql script name
SQLSCRIPTNAME=dms_prep_db.sql
declare -a ARGS=()

# Script specific

# ################################## Business functions

_cleanupSqlScript_() {
    if [ -f "$SQLSCRIPTNAME" ]; then
      rm ${SQLSCRIPTNAME}
    fi
}
# end  _cleanupSqlScript_

_readPrepMigrationParams_() {
    echo '-- Oracle Cloud Infrastructure Database Migration Service --'
    echo 'This script will help you prepare your source and target databases for migration.'
    echo 'Please answer the following questions to proceed:'
    echo

    read -r -p 'Database type [(s)ource/(t)arget]?: ' DBTYPE

    # If is source db
    if [[ "$DBTYPE" == [sS]* ]]; then
        ISTGTDB=NO;
        read -r -p 'Is your source database hosted in AWS RDS (Amazon Relational Database Service)? [y/n]: ' input
        if [[ "$input" == [yY]* ]]; then
            ISRDS=YES;
            DBTENANT=s;
        fi

        if [ $ISRDS == 'NO' ]; then
          read -r -p 'Is it an Autonomous database? [y/n]: ' input
          if [[ "$input" == [yY] ]]; then
            ISADB=YES;
          else
            read -r -p 'Is your database multi-tenant or single-tenant? [(m)ulti/(s)ingle]: ' DBTENANT
            if [[ "$DBTENANT" == [mM]* ]]; then
               ISMULTITENANT=YES;
               read -r -p 'Please provide your PDB service name (e.g. amer.subnet1.alimavcn.oraclevcn.com): ' PDBSERVICENAME
            fi
          fi
        fi

        read -r -p 'Migration type [(on)line/(off)line]: ' MIGTYPE
        if [[ "$MIGTYPE" == [oO][fF][fF]* ]]; then
            if [[ $ISADB == 'YES' ]]; then
              SCRIPTTYPE=$SRC_OFFLINE_ADB;
            elif [[ "$DBTENANT" == [sS]* ]]; then
                if [ $ISRDS == 'YES' ]; then
                    SCRIPTTYPE=$SRC_OFFLINE_NONPDB_RDS
                else
                  SCRIPTTYPE=$SRC_OFFLINE_NONPDB
                fi
            elif [[  "$DBTENANT" == [mM]* ]]; then
                SCRIPTTYPE=$SRC_OFFLINE_PDB
            fi
            if [ $ISRDS == 'NO' ]; then
              if [[ $ISADB == 'YES' ]]; then
                read -r -p 'Initial load database username (ggadmin is recommended): ' INITIALLOADUSR
              else
                read -r -p 'Initial load database username (system is recommended): ' INITIALLOADUSR
              fi
              read -r -sp "Password for ${INITIALLOADUSR} user: " INITIALLOADPWD
              echo
            fi

        elif [[ "$MIGTYPE" == [oO][nN]* ]]; then
            if [ $ISRDS == 'NO' ]; then
                read -r -p 'Initial load database username (ggadmin is recommended): ' INITIALLOADUSR
                read -r -sp "Password for ${INITIALLOADUSR} user: " INITIALLOADPWD
                echo
            fi

            if [[ $ISADB == 'YES' ]]; then
                SCRIPTTYPE=$SRC_ONLINE_ADB;
                read -r -p 'Replication user must be ggadmin for Autonomous Databases (press Enter to continue)'
                if [[ ${INITIALLOADUSR} == "${PDBREPLICATIONUSR}" ]]; then
                  GGADMINPWD=${INITIALLOADPWD}
                else
                  read -r -sp "Password for ${PDBREPLICATIONUSR} user: " GGADMINPWD
                fi

            elif [[ "$DBTENANT" == [sS]* ]]; then
                SCRIPTTYPE=$SRC_ONLINE_NONPDB
                if [ $ISRDS == 'YES' ]; then
                  SCRIPTTYPE=$SRC_ONLINE_NONPDB_RDS
                fi
                read -r -p 'Are you using ggadmin as the replication database username (recommended)? [y/n]: ' input
                if [[ "$input" == [nN]* ]]; then
                    read -r -p 'Replication database username (instead of ggadmin): ' PDBREPLICATIONUSR
                fi
                if [[ $ISRDS == 'NO' && {$PDBREPLICATIONUSR^^} == {$INITIALLOADUSR^^} ]]; then
                  GGADMINPWD=$INITIALLOADPWD;
                else
                  read -r -sp "Password for ${PDBREPLICATIONUSR} user: " GGADMINPWD
                  echo
                fi
            else
                SCRIPTTYPE=$SRC_ONLINE_PDB
                read -r -p 'Are you using ggadmin/c##ggadmin as the replication database usernames (recommended)? [y/n]: ' input
                if [[ "$input" == [nN]* ]]; then
                    read -r -p 'Replication database username (instead of ggadmin): ' PDBREPLICATIONUSR
                    read -r -p 'Replication database username (instead of c##ggadmin): ' CDBREPLICATIONUSR
                fi
                if [[ $ISRDS == 'NO' && {$PDBREPLICATIONUSR^^} == {$INITIALLOADUSR^^} ]]; then
                  GGADMINPWD=$INITIALLOADPWD;
                else
                  read -r -sp "Password for ${PDBREPLICATIONUSR}/${CDBREPLICATIONUSR} user: " GGADMINPWD
                  echo
                fi
            fi
        fi

    # if is target DB
    elif [[ "$DBTYPE" == [tT]* ]]; then
        ISTGTDB=YES;
        read -r -p 'Migration type [(on)line/(off)line]: ' MIGTYPE
        read -r -p 'Is it an Autonomous database? [y/n]: ' input

        # if is Autonomous
        if [[ "$input" == [yY] ]]; then
            ISADB=YES;
            if [[ "$MIGTYPE" == [oO][fF][fF]* ]]; then
                SCRIPTTYPE=$TGT_OFFLINE_ATP;
            elif [[ "$MIGTYPE" == [oO][nN]* ]]; then
                SCRIPTTYPE=$TGT_ONLINE_ATP;
                read -r -sp 'Password for ggadmin user: ' GGADMINPWD
                echo
            fi

        else
            # Ask for multi-tenant or single-tenant DB
            read -r -p 'Is your database multi-tenant or single-tenant? [(m)ulti/(s)ingle]: ' DBTENANT

            if [[ "$DBTENANT" == [mM]* ]]; then
               ISMULTITENANT=YES;
               read -r -p 'Please provide your PDB service name (e.g. amer.subnet1.alimavcn.oraclevcn.com): ' PDBSERVICENAME
            fi

            # Ask for initial load username and password
            if [[ "$MIGTYPE" == [oO][fF][fF]* ]]; then
                read -r -p 'Initial load database username (system recommended): ' INITIALLOADUSR
            elif [[ "$MIGTYPE" == [oO][nN]* ]]; then
                read -r -p 'Initial load database username (ggadmin is recommended): ' INITIALLOADUSR
            fi
            read -r -sp "Password for ${INITIALLOADUSR} user: " INITIALLOADPWD
            echo

            # If is online migration, ask for the ggadmin password
            if [[ "$MIGTYPE" == [oO][nN]* ]]; then
                read -r -p 'Are you using ggadmin as the replication database username (recommended)? [y/n]: ' input
                if [[ "$input" == [nN]* ]]; then
                    read -r -p 'Replication database username (instead of ggadmin): ' PDBREPLICATIONUSR
                fi
                if [[ {$PDBREPLICATIONUSR^^} == {$INITIALLOADUSR^^} ]]; then
                  GGADMINPWD=$INITIALLOADPWD;
                else
                  read -r -sp "Password for ${PDBREPLICATIONUSR} user: " GGADMINPWD
                  echo
                fi
            fi

            # Set the script type according the previous inputs
            if [[ "$DBTENANT" == [sS]* ]]; then
                if [[ "$MIGTYPE" == [oO][nN]* ]]; then
                    SCRIPTTYPE=$TGT_ONLINE_NON_PDB;
                else
                    SCRIPTTYPE=$TGT_OFFLINE_NON_PDB;
                fi
            else
                if [[ "$MIGTYPE" == [oO][nN]* ]]; then
                    SCRIPTTYPE=$TGT_ONLINE_PDB;
                else
                    SCRIPTTYPE=$TGT_OFFLINE_PDB;
                fi
            fi
        fi

    fi # end if DBTYPE (source/target)

    # set extra variables for the sql script
    if [[ "$MIGTYPE" == [oO][nN]* ]]; then
      ISONLINEMIG=YES;
    else
      ISONLINEMIG=NO;
    fi


}
# end _readPrepMigrationParams_

_dbPrepSqlScript_() {
  cat <<- EOF >> ${SQLSCRIPTNAME}
-- -------------------------------------------------------------------------------------------------------
-- Copyright (c) 2023 Oracle and/or its affiliates.  All rights reserved.
-- Licensed under the Universal Permissive License v 1.0 as shown at http://oss.oracle.com/licenses/upl.
--
-- File Name    : dms_prep_db.sql
-- Description  : Lists all changes needed in the database to prepare it for a migration
-- Call Syntax  : @dms_prep_db
-- Output file  : DMS_Configuration.sql
-- Requirements : sysdba at CDB root container or nonCDB
-- Last Modified: 01 Jul 2025
-- -------------------------------------------------------------------------------------------------------
spool DMS_Configuration.sql
SET SERVEROUTPUT ON
SET VERIFY OFF
CLEAR SCREEN
SET FEEDBACK OFF
SET LINE 300
DECLARE

    -- Constant Values from the user choices in dms-prep-db bash script
    c_pdb_service_name        VARCHAR2(200) := '$PDBSERVICENAME';
    c_db_password             VARCHAR2(100) := '$GGADMINPWD';
    c_initial_load_user       VARCHAR2(100) := '${INITIALLOADUSR^^}';
    c_initial_load_pwd        VARCHAR2(100) := '$INITIALLOADPWD';
    c_is_online_mig           VARCHAR2(20)  := '$ISONLINEMIG';
    c_is_target_db            VARCHAR2(20)  := '$ISTGTDB';
    c_is_db_rds_allocated     VARCHAR2(20)  := '$ISRDS';
    c_is_multitenant          VARCHAR2(20)  := '$ISMULTITENANT';
    c_cdb_user                VARCHAR2(20)  := '${CDBREPLICATIONUSR^^}';
    c_pdb_user                VARCHAR2(20)  := '${PDBREPLICATIONUSR^^}';
    c_noncdb_user             VARCHAR2(20)  := '${PDBREPLICATIONUSR^^}';

    -- Other Constant values
    c_system_user                 VARCHAR2(20)  := 'SYSTEM';
    c_ggadmin_user                VARCHAR2(20)  := 'GGADMIN';
    c_ogg_tablespace              VARCHAR2(10)  := 'GG_ADMIN';
    c_job_queue_processes         VARCHAR2(20)  := 'JOB_QUEUE_PROCESSES';
    c_db_ver_12_1_0_2             VARCHAR2(20)  := '12.1.0.2';

    -- Exceptions
    c_user_abort_execution        EXCEPTION;
    c_cdb_user_invalid            EXCEPTION;
    c_pdb_user_invalid            EXCEPTION;
    c_noncdb_user_invalid         EXCEPTION;
    c_db_password_invalid         EXCEPTION;
    c_initial_load_user_invalid   EXCEPTION;
    c_initial_load_pwd_invalid    EXCEPTION;
    c_initial_load_user_not_exist EXCEPTION;
    c_pdb_service_name_invalid    EXCEPTION;
    c_password_reused_exeption    EXCEPTION;
    PRAGMA EXCEPTION_INIT(c_password_reused_exeption, -28007);

    -- Current State Variable
    v_db_name                     VARCHAR2(50);
    v_instance_name               VARCHAR2(50);
    v_db_unique_name              VARCHAR2(50);
    v_log_mode                    VARCHAR2(50);
    v_force_logging               VARCHAR2(50);
    v_supplemental                VARCHAR2(50);
    v_stream_pool_size            VARCHAR2(50);
    v_enable_ogg_rep              VARCHAR2(50);
    v_global_names                VARCHAR2(50);
    v_is_cdb                      VARCHAR2(20);
    v_is_rac                      NUMBER(10);
    v_is_autonomous               VARCHAR2(20);
    v_printing                    VARCHAR2(50);
    v_recommended_stream          NUMBER := 2048;
    v_cdb_service_name            VARCHAR2(100);
    v_pdb_service_name            VARCHAR2(100);
    v_noncdb_service_name         VARCHAR2(100);
    v_period_pos                  NUMBER;
    v_host_name                   VARCHAR2(50);
    v_pdb_name                    VARCHAR2(50);
    v_restart                     VARCHAR2(20);
    v_is_db_gg_ready              BOOLEAN;
    v_cdb_package_executed        VARCHAR2(10);
    v_pdb_package_executed        VARCHAR2(10);
    v_noncdb_package_executed     VARCHAR2(10);
    v_pdb_service_name_exist      VARCHAR2(100);
    v_dv_enabled                  VARCHAR2(60);
    v_is_pdb_dba_role             VARCHAR2(20);
    v_db_version                  VARCHAR2(20);
    v_db_version_full             VARCHAR2(20);
    v_is_db_ver_prior_12_1_0_2    VARCHAR(20);
    v_job_queue_proc_pdb_changed  VARCHAR(10);
    v_job_queue_processes_cdb     NUMBER;
    v_job_queue_processes_pdb     NUMBER;
    v_job_queue_proc_min_cdb      NUMBER;
    v_job_queue_proc_min_pdb      NUMBER;
    v_sql_text                    VARCHAR2(5000);
    v_event_table_exists          VARCHAR2(20);
    v_gg_user                     VARCHAR2(20);

    --- Users and Tablespace Variables
    v_data_file_name              VARCHAR2(200);
    v_asm_diskegroup              VARCHAR2(200);
    v_file_system                 VARCHAR2(200);
    v_os_slash                    VARCHAR2(100);
    v_cdb_user                    VARCHAR2(20);
    v_pdb_user                    VARCHAR2(20);
    v_ggadmin_user                VARCHAR2(20);
    v_cdb_tablespace              VARCHAR2(3);
    v_pdb_tablespace              VARCHAR2(3);
    v_pdb_data_file_name          VARCHAR2(100);
    v_noncdb_user                 VARCHAR2(10);
    v_noncdb_tablespace           VARCHAR2(3);
    v_match_found                 BOOLEAN := FALSE;
    v_match_to_print              VARCHAR2(50);
    v_db_domain                   VARCHAR2(50);
    v_is_noncdb_usr_locked        VARCHAR2(20);
    v_is_cdb_usr_locked           VARCHAR2(20);
    v_is_pdb_usr_locked           VARCHAR2(20);
    v_is_initial_load_usr_locked  VARCHAR2(20);
    v_initial_load_usr_exists     VARCHAR2(20);
    v_initial_load_usr_in_pdb     VARCHAR2(20);
    v_is_ggadmin_usr_locked       VARCHAR2(20);

    -- Migration variables
    v_migration_type              VARCHAR2(20);
    v_mig_db_type                 VARCHAR2(20);

    -- Grants for the CDB Container
    type privs_array IS VARRAY(50) OF VARCHAR2(50);
    v_cdb_privs privs_array := privs_array(  -- CDB online (c##ggadmin)
    'CREATE SESSION',
    'CREATE VIEW',
    'CREATE TABLE',
    'ALTER SYSTEM',
    'SELECT ANY DICTIONARY',
    --'EXECUTE ON dbms_lock' -- Done by DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE
    --'SELECT_CATALOG_ROLE', -- Done by DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE
    'DV_GOLDENGATE_ADMIN',
    'DV_GOLDENGATE_REDO_ACCESS'
    );

    -- Grants for the PDB Container and NonCDB Databases
    v_pdb_privs privs_array := privs_array( -- PDB online / Single tenant online (ggadmin)
    'CREATE SESSION',
    --'SELECT_CATALOG_ROLE',  -- Done by DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE
    'DV_GOLDENGATE_ADMIN',
    'DV_GOLDENGATE_REDO_ACCESS',
    'ALTER SYSTEM',
    'ALTER USER',
    'DATAPUMP_EXP_FULL_DATABASE',
    'DATAPUMP_IMP_FULL_DATABASE',
    'READ ON DIRECTORY DATA_PUMP_DIR',
    'WRITE ON DIRECTORY DATA_PUMP_DIR',

    -- For replication purposes
    'SELECT ANY DICTIONARY',
    'SELECT ANY TRANSACTION',
    'INSERT ANY TABLE',
    'UPDATE ANY TABLE',
    'DELETE ANY TABLE',
    'LOCK ANY TABLE',
    'DROP ANY TABLE',
    'DROP ANY INDEX',
    'DROP ANY VIEW',
    'DROP ANY PROCEDURE',
    'SELECT ON V_\$SESSION',
    'SELECT ON V_\$TRANSACTION',
    'SELECT ON V_\$DATABASE',

    -- Needed for creating checkpoint, heartbeat tables and the table creations in the DDL replications.
    'CREATE ANY TABLE',
    'CREATE ANY INDEX',

    -- DDL privileges for the DDL replication
    'CREATE ANY CLUSTER',
    'CREATE ANY INDEXTYPE',
    'CREATE ANY OPERATOR',
    'CREATE ANY PROCEDURE',
    'CREATE ANY SEQUENCE',
    'CREATE ANY TRIGGER',
    'CREATE ANY TYPE',
    'CREATE ANY SEQUENCE',
    'CREATE ANY VIEW',
    'ALTER ANY TABLE',
    'ALTER ANY INDEX',
    'ALTER ANY CLUSTER',
    'ALTER ANY INDEXTYPE',
    'ALTER ANY OPERATOR',
    'ALTER ANY PROCEDURE',
    'ALTER ANY SEQUENCE',
    'ALTER ANY TRIGGER',
    'ALTER ANY TYPE',
    'ALTER ANY SEQUENCE',
    'CREATE DATABASE LINK'
    --'EXECUTE ON dbms_lock' -- Done by DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE
    );

    -- Grants for the NonCDB RDS Databases
    v_noncdb_rds_privs privs_array := privs_array(
    'UNLIMITED TABLESPACE',
    'SELECT ANY DICTIONARY',
    'CREATE VIEW',
    --'EXECUTE ON DBMS_LOCK', -- Done by DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE
    'SELECT ON SYS.CDEF\$',
    'SELECT ON SYS.COL\$',
    'SELECT ON SYS.CON\$',
    'SELECT ON SYS.OBJ\$',
    'SELECT ON SYS.SEG\$',
    'SELECT ON SYS.TAB\$'
    );

    -- Grants for GGADMIN when is not the replication user
    v_ggadmin_no_rep_privs privs_array := privs_array(
    'SELECT ANY DICTIONARY',
    'SELECT ANY TRANSACTION',
    'SELECT ON V_\$SESSION',
    'SELECT ON V_\$TRANSACTION',
    'SELECT ON V_\$DATABASE'
    );

    -- Privileges for ADB Databases user (ggadmin)
    -- for the creation of the event table and its trigger
    -- (only when the ADB is source DB)
    v_adb_src_evnt_table_privs privs_array := privs_array(
    'SELECT ON V\$TRANSACTION',
    'SELECT ON SYS.V_\$SESSION',
    'SELECT ON SYS.V_\$TRANSACTION',
    'SELECT ON SYS.V_\$DATABASE'
    );

    -- Grants for the Initial Load User
    -- when it is different from Replication User
    v_initial_load_privs privs_array := privs_array(
    'CREATE SESSION',
    'DATAPUMP_EXP_FULL_DATABASE',
    'DATAPUMP_IMP_FULL_DATABASE',
    'SELECT ANY DICTIONARY',
    'EXECUTE ON UTL_HTTP'
    );

    -- Cursor to check user privileges
    privilege_cur SYS_REFCURSOR;
    granted_privs VARCHAR2(100);


    --  Proc to print the output line
    PROCEDURE DBMS_OUTPUT_PUT_LINE (p_print1 VARCHAR2)
    IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(p_print1);
    END;

    PROCEDURE get_pdb_name
    IS
    BEGIN
        -- Check if database is Multi-tenant
        if to_number(v_db_version) < 12 then
            v_is_cdb := 'N/A';
            c_is_multitenant := 'NO';
        else
            EXECUTE IMMEDIATE('select cdb from v\$database') into v_is_cdb;
        end if;
        -- Check if databse have db_domain enabled, this will be used to validate the service_name and pdb
        select nvl(value, null) into v_db_domain
        from v\$parameter where name = 'db_domain';

        -- Check if the servicename entered is valid and assing the PDB name to the process based on the same service name.
        if v_is_autonomous = 'NO' and c_is_db_rds_allocated = 'NO' then
            if c_is_multitenant = 'YES' then

                EXECUTE IMMEDIATE(
                    'select distinct upper(pdb)
                    from v\$services
                    where upper(network_name) =  upper('''||c_pdb_service_name||''')
                     or   upper(network_name) =  upper('''||c_pdb_service_name||'.'||v_db_domain||''')
                     or   upper(network_name) =  upper('''||SUBSTR(c_pdb_service_name, 1, INSTR(c_pdb_service_name, '.') - 1)||''')')
                INTO v_pdb_name;

                -- If PDB is not populated, error will be displayed
                if v_pdb_name is null then
                    raise c_pdb_service_name_invalid;
                end if;


                -- Get the current number of Job queue processes, and its desired value --
                -- For CDB
                SELECT value into v_job_queue_processes_cdb FROM V\$PARAMETER WHERE UPPER(name) = c_job_queue_processes;
                EXECUTE IMMEDIATE('SELECT COUNT(1)*2 FROM V\$CONTAINERS WHERE open_mode != ''MOUNTED''' )
                INTO v_job_queue_proc_min_cdb;
                if v_job_queue_processes_cdb > v_job_queue_proc_min_cdb then
                    v_job_queue_proc_min_cdb := v_job_queue_processes_cdb;
                end if;

                -- For PDB
                EXECUTE IMMEDIATE(
                    'SELECT decode(count(1), 0, ''NO'', ''YES'')
                    FROM v\$system_parameter sp, V\$CONTAINERS c
                    WHERE UPPER(c.name) = UPPER('''||v_pdb_name||''')
                        and c.con_id = sp.con_id
                        and UPPER(sp.name) = '''||c_job_queue_processes||''''
                ) INTO v_job_queue_proc_pdb_changed;

                v_job_queue_processes_pdb := v_job_queue_processes_cdb;
                if v_job_queue_proc_pdb_changed = 'YES' then
                    EXECUTE IMMEDIATE(
                        'SELECT sp.value FROM v\$system_parameter sp, V\$CONTAINERS c
                        WHERE UPPER(c.name) = UPPER('''||v_pdb_name||''')
                            and c.con_id=sp.con_id
                            and UPPER(sp.name) = '''||c_job_queue_processes||''''
                    ) INTO v_job_queue_processes_pdb;
                end if;

                if v_job_queue_processes_pdb < 2 then
                    v_job_queue_proc_min_pdb := 2;
                else
                    v_job_queue_proc_min_pdb := v_job_queue_processes_pdb;
                end if;

            else
                if to_number(v_db_version) > 11 then
                    -- For single tenant DBs after version 11g
                    EXECUTE IMMEDIATE(
                        'select max(distinct upper(pdb))
                        from v\$services where upper(pdb) not like ''%CDB%''')
                    INTO v_pdb_name;
                else
                    v_pdb_name := '';
                end if;
            end if;
        else
            v_pdb_name := '';
        end if;

        EXCEPTION
            WHEN TOO_MANY_ROWS then
              DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
              DBMS_OUTPUT_PUT_LINE('--          Database GoldenGate Error  ');
              DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
              DBMS_OUTPUT_PUT_LINE('--');
              DBMS_OUTPUT_PUT_LINE('-20102,TOO MANY ROWS, The service name '''||upper(c_pdb_service_name)||''' entered was not found.  Please review the service name provided. ');
    END; --get_pdb_name


    PROCEDURE check_database
    IS
    BEGIN
        --Check for constant parameters, raise error if it's not set
        if c_cdb_user is NULL then
            RAISE c_cdb_user_invalid;
        elsif c_db_password is NULL then
            RAISE c_db_password_invalid;
        elsif c_initial_load_user is NULL then
            RAISE c_initial_load_user_invalid;
        elsif c_initial_load_pwd is NULL then
            RAISE c_initial_load_pwd_invalid;
        elsif c_pdb_user is NULL then
            RAISE c_pdb_user_invalid;
        elsif c_noncdb_user is NULL then
            RAISE c_noncdb_user_invalid;
        end if;

        if c_is_online_mig = 'YES' then
            v_migration_type := 'ONLINE';
        else
            v_migration_type := 'OFFLINE';
        end if;

        if c_is_target_db = 'YES' then
            v_mig_db_type := 'TARGET';
        else
            v_mig_db_type := 'SOURCE';
        end if;

        -- Check general database status
        select host_name into v_host_name from v\$instance;
        select name into v_db_name from v\$database;
        select instance_name into v_instance_name from v\$instance;
        select db_unique_name into v_db_unique_name from v\$database;
        select decode(log_mode, 'ARCHIVELOG', 'YES', 'NO') into v_log_mode from v\$database;
        select force_logging into v_force_logging from v\$database;
        select supplemental_log_data_min into v_supplemental from v\$database;
        select value into v_enable_ogg_rep from v\$parameter  where name='enable_goldengate_replication';
        select value into v_global_names from v\$parameter where name = 'global_names';

        -- Get DB Version
        select SUBSTR(version, 1, INSTR(version, '.') - 1) into v_db_version from v\$instance;
        select decode(REGEXP_COUNT(version, '\.')-3, 0, version, SUBSTR(version, 1, INSTR(version, '.', -1) - 1))
            into v_db_version_full from v\$instance;
        select (case when v_db_version_full < c_db_ver_12_1_0_2 then 'YES' else 'NO' end)
            into v_is_db_ver_prior_12_1_0_2 from dual;

        -- Check if database is Autonomous
        if to_number(v_db_version) >= 23 then
            execute immediate 'SELECT decode(cloud_identity,NULL,''NO'',''YES'') FROM v\$pdbs WHERE rownum = 1' into v_is_autonomous;
        else
            select decode(count(1),1,'YES','NO') into v_is_autonomous from all_tab_columns where upper(table_name) = 'V_\$PDBS' and upper(column_name) = 'CLOUD_IDENTITY';
        end if;
        if v_is_autonomous = 'YES' then
            execute immediate 'SELECT JSON_VALUE(a.cloud_identity, ''\$.DATABASE_NAME'') FROM (SELECT cloud_identity FROM v\$pdbs) a' into v_db_name;
        end if;

        -- Check if the database is RAC (Clustered)
        select count(*) into v_is_rac from v\$instance;

        -- Check if database has Data Vault enabled
        select value into v_dv_enabled from v\$option where parameter ='Oracle Database Vault';

        -- Check for CDB service name
        if v_is_autonomous = 'NO' then
            select value into v_cdb_service_name from v\$parameter where name = 'service_names';
        else
            v_cdb_service_name := '';
        end if;

        -- Define the best value for Stream Pool Size, 1G is the recomended value or 10% of the SGA size, whichever is the lower.
        -- for OGG Free we recommend 512M if streams_pool_size is set to 0 or lower then 512M.
        select round(value/1024/1024) into v_stream_pool_size from v\$parameter  where name='streams_pool_size';

        -- PDB name is require to create the appropriated user and grant privileges for GoldenGate
        get_pdb_name;

        -- Check if initial load user exists
        v_initial_load_usr_in_pdb := 'NO';
        if v_is_autonomous = 'NO' and c_is_multitenant = 'YES' then
            EXECUTE IMMEDIATE(
            'select decode(count(*),1,''YES'',''NO'') from cdb_users
            where upper(username) = upper('''||c_initial_load_user||''')
            and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||'''))') INTO v_initial_load_usr_exists;  -- Local User
        else
            select decode(count(*),1,'YES','NO') into v_initial_load_usr_exists from dba_users where upper(username) = upper(c_initial_load_user);  -- Global User
        end if;

        -- Check if initial load user is locked
        if v_initial_load_usr_exists = 'YES' then
            if v_is_autonomous = 'NO' and c_is_multitenant = 'YES' then
                v_initial_load_usr_in_pdb := 'YES';
                EXECUTE IMMEDIATE(
                'select decode(count(*),0,''YES'',''NO'') from cdb_users
                where upper(username) = upper('''||c_initial_load_user||''') and account_status = ''OPEN''
                and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||'''))') INTO v_is_pdb_usr_locked;  -- Local User Locked
            else
                select decode(account_status,'OPEN','NO','YES') into v_is_initial_load_usr_locked from dba_users where username=upper(c_initial_load_user); -- Global User Locked
            end if;
        elsif upper(c_initial_load_user) != upper(c_pdb_user) or upper(c_initial_load_user) != upper(c_noncdb_user) then
            RAISE c_initial_load_user_not_exist;
        end if;

        -- Check if CDB Users and Tablespace exists
        if v_is_autonomous = 'NO' and c_is_multitenant = 'YES' then
            select decode(count(*),1,'YES','NO') into v_cdb_user from dba_users where upper(username) = upper(c_cdb_user);  -- CDB User
            select decode(count(*),1,'YES','NO') into v_cdb_tablespace from dba_tablespaces where upper(tablespace_name) = upper(c_ogg_tablespace);  -- CDB Tablespace
            select decode(count(*),0,'YES','NO') into v_is_cdb_usr_locked from dba_users where upper(username) = upper(c_cdb_user) and upper(account_status) = 'OPEN';  -- CDB User Locked
            v_gg_user := c_pdb_user;
            -- Check if PDB User and Tablespace exist
            EXECUTE IMMEDIATE(
            'select decode(count(*),1,''YES'',''NO'') from cdb_users
                where upper(username) = upper('''||c_pdb_user||''')
                and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||'''))') INTO v_pdb_user;  -- PDB User
            EXECUTE IMMEDIATE(
            'select decode(count(*),1,''YES'',''NO'') from cdb_tablespaces
                where upper(tablespace_name) = upper('''||c_ogg_tablespace||''')
                and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||'''))') INTO v_pdb_tablespace;  -- PDB Tablespace
            EXECUTE IMMEDIATE(
            'select decode(count(*),0,''YES'',''NO'') from cdb_users
                where upper(username) = upper('''||c_pdb_user||''') and account_status = ''OPEN''
                and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||'''))') INTO v_is_pdb_usr_locked;  -- PDB User Locked
        else
            -- Check NonCDB user and tablespace
            select decode(count(*),1,'YES','NO') into v_noncdb_user from dba_users where username = upper(c_noncdb_user);
            select decode(count(*),1,'YES','NO') into v_noncdb_tablespace from dba_tablespaces where tablespace_name = upper(c_ogg_tablespace);
            select decode(count(*),0,'YES','NO') into v_is_noncdb_usr_locked from dba_users where upper(username) = upper(c_noncdb_user) and account_status = 'OPEN';
            v_gg_user := c_noncdb_user;
        end if;

        -- Check if event_table exists (for online migrations only)
        if c_is_online_mig = 'YES' then
            if v_gg_user != c_ggadmin_user then
                -- Check ggadmin user in case is not the selected GoldenGate user
                if v_is_autonomous = 'NO' and c_is_multitenant = 'YES' then
                    EXECUTE IMMEDIATE(
                    'select decode(count(*),1,''YES'',''NO'') from cdb_users
                        where upper(username) = upper('''||c_ggadmin_user||''')
                        and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||'''))') INTO v_ggadmin_user;  -- GGADMIN User
                    EXECUTE IMMEDIATE(
                    'select decode(count(*),0,''YES'',''NO'') from cdb_users
                        where upper(username) = upper('''||c_ggadmin_user||''') and account_status = ''OPEN''
                        and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||'''))') INTO v_is_ggadmin_usr_locked;  -- GGADMIN User Locked
                else
                    select decode(count(*),1,'YES','NO') into v_ggadmin_user from dba_users where username = upper(c_ggadmin_user);
                    select decode(count(*),0,'YES','NO') into v_is_ggadmin_usr_locked from dba_users where upper(username) = upper(c_ggadmin_user) and account_status = 'OPEN';
                end if;
            end if;
        end if;

    END;

    -----------------------------------------------------------------------------------
    -- Proc to Generate the DDL for the create tablespace
    -- It checks if the file system is ASM diskgroup, Linux or Windows file system
    -----------------------------------------------------------------------------------
    PROCEDURE create_tablespace(p_pdb VARCHAR2)
    IS
    BEGIN
        --------------------------------------
        --  Create tablespaces
        --------------------------------------
        if p_pdb = 'CDB' or p_pdb = 'nonCDB' then
            select file_name into v_data_file_name from dba_data_files where tablespace_name='SYSTEM' and rownum=1;
        else
            EXECUTE IMMEDIATE(
            'select file_name from cdb_data_files
                where con_id = (select con_id from v\$pdbs where name = upper('''||v_pdb_name||'''))
                and tablespace_name=''SYSTEM'' and rownum=1') INTO v_data_file_name;
        end if;
        --  Check is data files is in ASM Diskgroup or OS File System
        IF REGEXP_LIKE(v_data_file_name, '^\+') = "TRUE" THEN
            v_asm_diskegroup:=substr(v_data_file_name,1,instr(v_data_file_name, '/', 1, 1));
            DBMS_OUTPUT_PUT_LINE('CREATE TABLESPACE '||c_ogg_tablespace||' DATAFILE ''' || v_asm_diskegroup ||''' SIZE 100m AUTOEXTEND ON NEXT 100m;');
        ELSE
            -- Check if plataform is Windows or UNIX for slash position
            if to_number(v_db_version) < 12 then
                v_os_slash := '/';
            else
                SELECT SYS_CONTEXT('USERENV', 'PLATFORM_SLASH') INTO v_os_slash FROM DUAL;
            end if;

            if v_os_slash = '/' then
                v_file_system:=substr(v_data_file_name,1,instr(v_data_file_name, '/', -1, 1)-1);  -- UNIX/Linux slah
            else
                v_file_system:=substr(v_data_file_name,1,instr(v_data_file_name, '\', -1, 1)-1);  -- Windows slash
            end if;
            DBMS_OUTPUT_PUT_LINE('CREATE TABLESPACE '||c_ogg_tablespace||' DATAFILE ''' || v_file_system ||''|| v_os_slash ||'ggadmin_data.dbf'' SIZE 100m AUTOEXTEND ON NEXT 100m;');
        END IF;
    END;

    -------------------------------------------------------------------------------------------------------
    -- Proc to verify if the user p_user has already granted the privs in p_privs_array; in
    -- affirmative case prints out a notice on that, otherwise prints the corresponding
    -- grant instruction.
    -- Parameters:
    --   p_privs_query   Query text to get the list of current grants for the user p_user.
    --                   The query must provide a single column with the privileges as granted_privs.
    --   p_privs_array   Array with the list of desired privs to be granted to p_user.
    --   p_user          Name of the user to grant the privileges.
    --   p_container     Container where the privileges must be granted.
    --                   Possible values: 'CURRENT', 'ALL' or 'NONE' for no container.
    --   p_is_RDS        TRUE if the privilege are being granted in an RDS database, FALSE otherwise.
    --   p_w_admin_opt   TRUE if it's desired to grant the privileges with admin option, FALSE otherwise.
    -------------------------------------------------------------------------------------------------------
    PROCEDURE check_current_grants(p_privs_query VARCHAR2, p_privs_array privs_array, p_user VARCHAR2,
                    p_container VARCHAR2, p_is_RDS BOOLEAN DEFAULT FALSE, p_w_admin_opt BOOLEAN DEFAULT FALSE)
    IS
        v_container_text    VARCHAR2(50);
        v_w_admin_opt_text  VARCHAR2(50);
    BEGIN
        if p_container = 'CURRENT' or p_container = 'ALL' then
            v_container_text := ' CONTAINER=' || p_container;
        else
            v_container_text := '';
        end if;

        if p_w_admin_opt then
            v_w_admin_opt_text := ' WITH ADMIN OPTION';
        else
            v_w_admin_opt_text := '';
        end if;

        -- Outer loop iterates through each element in the privs Array list
        v_match_found:= FALSE;
        FOR i IN 1 .. p_privs_array.count
        LOOP
            -- Inner loop iterates through each element in the database list
            open privilege_cur for p_privs_query;
            LOOP
                FETCH privilege_cur into granted_privs;
                EXIT WHEN privilege_cur%NOTFOUND;
                -- Compare the current element in the first list to the current element in the second list
                if granted_privs = p_privs_array(i) then
                     v_match_found:= TRUE;
                     exit;
                else
                     v_match_found:= FALSE;
                end if;
            END LOOP ;  --Inner For Loop
            close privilege_cur;

            -- Print privileged to be granted not found in the database
            if v_match_found = FALSE then
                if p_container = 'ALL' then
                    DBMS_OUTPUT_PUT_LINE('GRANT ' ||v_cdb_privs(i)||' TO '||c_cdb_user||' CONTAINER=ALL;');
                else
                    if p_is_RDS and instr(p_privs_array(i), 'SELECT ON SYS.') > 0 then
                       DBMS_OUTPUT_PUT_LINE('EXEC RDSADMIN.RDSADMIN_UTIL.GRANT_SYS_OBJECT('''||
                            substr(p_privs_array(i), instr(p_privs_array(i), '.')+1)||''', '''||p_user||''', ''SELECT'');');
                    -- Only grant Data Vault roleprivilege if database has Data Vault Enabled.
                    elsif instr(p_privs_array(i), 'DV_GOLDENGATE') > 0 and v_dv_enabled = 'TRUE' then
                       DBMS_OUTPUT_PUT_LINE('GRANT ' ||p_privs_array(i)||' TO '||p_user||v_w_admin_opt_text||v_container_text||';');
                    elsif instr(p_privs_array(i), 'DV_GOLDENGATE') = 0 then
                       DBMS_OUTPUT_PUT_LINE('GRANT ' ||p_privs_array(i)||' TO '||p_user||v_w_admin_opt_text||v_container_text||';');
                    end if;
                end if;
            else
                DBMS_OUTPUT_PUT_LINE('-- Privilege '||p_privs_array(i)||' already granted TO '||p_user);
            end if;

        END LOOP; -- Outer For Loop
    END;

--===================================================
-- MAIN
--===================================================
BEGIN
    /* Displaying General Database Information Output */

    -- Check database for GoldenGate required components
    check_database;

    --  Check if the database needs to be restarted and enable archived log mode
    if v_log_mode = 'YES' or c_is_db_rds_allocated = 'YES' then
        v_restart := 'NO';
    else
        v_restart := 'YES';
        v_is_db_gg_ready := FALSE;
    end if;

    DBMS_OUTPUT_PUT_LINE('--');
    DBMS_OUTPUT_PUT_LINE('-- The output shown below is informational. This is to provide you detail on the actions ');
    DBMS_OUTPUT_PUT_LINE('-- that will be performed when the generated script is ran on your database.');
    DBMS_OUTPUT_PUT_LINE('--');
    DBMS_OUTPUT_PUT_LINE('--');
    DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
    DBMS_OUTPUT_PUT_LINE('--          Database Information');
    DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
    DBMS_OUTPUT_PUT_LINE(rpad('--Database Name:                 ',32) || v_db_name);
    DBMS_OUTPUT_PUT_LINE(rpad('--Database Version:              ',32) || v_db_version_full);
    if v_is_autonomous = 'NO' then
        DBMS_OUTPUT_PUT_LINE(rpad('--Database Host Name:            ',32) || v_host_name);
        DBMS_OUTPUT_PUT_LINE(rpad('--Database Instance Name:        ',32) || v_instance_name);
        DBMS_OUTPUT_PUT_LINE(rpad('--Database Unique Name:          ',32) || v_db_unique_name);
        if c_is_multitenant = 'YES' then
            DBMS_OUTPUT_PUT_LINE(rpad('--Database is Container (CDB): ',32) || v_is_cdb);
            DBMS_OUTPUT_PUT_LINE(rpad('--Database CDB Service Name:   ',32) || upper(v_cdb_service_name));
            DBMS_OUTPUT_PUT_LINE(rpad('--Database PDB Service Name:   ',32) || upper(c_pdb_service_name));
            DBMS_OUTPUT_PUT_LINE(rpad('--Database CDB User Exist:     ',32) || rpad(upper(v_cdb_user),5)             ||' (User Name: '||c_cdb_user||')');
            DBMS_OUTPUT_PUT_LINE(rpad('--Database CDB User Locked:    ',32) || rpad(upper(v_is_cdb_usr_locked),5)    ||' (Required: NO)');
            DBMS_OUTPUT_PUT_LINE(rpad('--Database PDB User Exist:     ',32) || rpad(upper(v_pdb_user),5)             ||' (User Name: '||c_pdb_user||')');
            DBMS_OUTPUT_PUT_LINE(rpad('--Database PDB User Locked:    ',32) || rpad(upper(v_is_pdb_usr_locked),5)    ||' (Required: NO)');
        else
            DBMS_OUTPUT_PUT_LINE(rpad('--Database User:               ',32) || rpad(upper(v_noncdb_user),5)          ||' (User Name: '||c_pdb_user||')');
            DBMS_OUTPUT_PUT_LINE(rpad('--Database User locked:        ',32) || rpad(upper(v_is_noncdb_usr_locked),5) ||' (Required: NO)');
            DBMS_OUTPUT_PUT_LINE(rpad('--Database Service Name:       ',32) || rpad(upper(v_cdb_service_name),5));
        end if;
    -- When is an autonomous DB and online migration, show ggadmin user status
    elsif c_is_online_mig = 'YES' then
        DBMS_OUTPUT_PUT_LINE(rpad('--Database User:               ',32) || rpad(upper(v_noncdb_user),5) ||' (User Name:  '||c_noncdb_user||')');
        DBMS_OUTPUT_PUT_LINE(rpad('--Database User locked:        ',32) || rpad(upper(v_is_noncdb_usr_locked),5) ||' (Required: NO)');
    end if;
    DBMS_OUTPUT_PUT_LINE(rpad('--Database Global Names:          ',32)  || v_global_names);
    if (c_is_online_mig = 'YES' and c_is_target_db = 'NO') then
        DBMS_OUTPUT_PUT_LINE('--');
        DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
        DBMS_OUTPUT_PUT_LINE('--          Database GoldenGate Status  ');
        DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
        DBMS_OUTPUT_PUT_LINE(rpad('--Database Restart Required:   ',32) || rpad(v_restart,5));
        DBMS_OUTPUT_PUT_LINE(rpad('--Database Archived Log Mode:  ',32) || rpad(v_log_mode,5)         || '     (Required value for GoldenGate: YES)');
        DBMS_OUTPUT_PUT_LINE(rpad('--Database Force Logging Mode: ',32) || rpad(v_force_logging,5)    || '     (Required value for GoldenGate: YES)');
        DBMS_OUTPUT_PUT_LINE(rpad('--Database Supplemental Mode:  ',32) || rpad(v_supplemental,5)     || '     (Required value for GoldenGate: YES)');
        DBMS_OUTPUT_PUT_LINE(rpad('--Database Stream Pool Size Mb:',32) || rpad(v_stream_pool_size,5) || '     (Recommended value for GoldenGate: '|| v_recommended_stream ||'Mb)');
        DBMS_OUTPUT_PUT_LINE(rpad('--GoldenGate Enable Parameter: ',32) || rpad(v_enable_ogg_rep,5)   || '     (Required value for GoldenGate: TRUE)');
        if v_gg_user != c_ggadmin_user then
            DBMS_OUTPUT_PUT_LINE(rpad('--Database GGADMIN User Exist:  ',32) || rpad(v_ggadmin_user,5)          || '     (Required value for GoldenGate: YES)');
            DBMS_OUTPUT_PUT_LINE(rpad('--Database GGADMIN User Locked: ',32) || rpad(v_is_ggadmin_usr_locked,5) || '     (Required: NO)');
        end if;
    end if;

    DBMS_OUTPUT_PUT_LINE('--');
    DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
    DBMS_OUTPUT_PUT_LINE('--   Actions to be performed for preparing your '||v_mig_db_type||' Database for '||v_migration_type||' Migration ');
    DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
    DBMS_OUTPUT_PUT_LINE('--');
    ---------------------------------------------------------------------------------------------------------------
    -- This session will check if a database restart is required to enable Achived Log Mode required by GoldenGate
    ---------------------------------------------------------------------------------------------------------------
    --Check if a bounce is required and create the DDL for RAC or NON-RAC database bounce
    if c_is_target_db = 'NO' then
        if v_log_mode = 'YES' then
            if c_is_db_rds_allocated = 'NO' then
                DBMS_OUTPUT_PUT_LINE('-- Database is in Archived Log Mode, NO Restart required.');
            else
                DBMS_OUTPUT_PUT_LINE('-- Database is in Archived Log Mode, NO action required.');
            end if;
            DBMS_OUTPUT_PUT_LINE('--');
        else
            if c_is_db_rds_allocated = 'YES' then
                DBMS_OUTPUT_PUT_LINE('-- Database is not in Archived Log Mode, it is required Archive Log Retention to be set to 72 hours');
                DBMS_OUTPUT_PUT_LINE('-- Recommended Process:');
                DBMS_OUTPUT_PUT_LINE('-- EXEC RDSADMIN.RDSADMIN_UTIL.SET_CONFIGURATION(''ARCHIVELOG RETENTION HOURS'',72);');
            elsif v_is_rac > 1 then
                DBMS_OUTPUT_PUT_LINE('-- The database is RAC, it is not in Archived Log Mode and a database Restart is required.');
                DBMS_OUTPUT_PUT_LINE('-- Recommended Process:');
                DBMS_OUTPUT_PUT_LINE('--SRVCTL STOP DATABASE -db '||v_db_unique_name||' -stopoption immediate;');
                DBMS_OUTPUT_PUT_LINE('--SRVCTL START DATABASE -db '||v_db_unique_name||' -startoption mount;');
                DBMS_OUTPUT_PUT_LINE('--ALTER DATABASE ARCHIVELOG;');
                DBMS_OUTPUT_PUT_LINE('--SRVCTL STOP DATABASE -db '||v_db_unique_name||' -stopoption immediate;');
                DBMS_OUTPUT_PUT_LINE('--SRVCTL START DATABASE -db '||v_db_unique_name||';');
                DBMS_OUTPUT_PUT_LINE('--SRVCTL STATUS DATABASE -db '||v_db_unique_name||';');
            else
                DBMS_OUTPUT_PUT_LINE('-- The database is non-RAC, its not in Archived Log Mode and a database Restart is required.');
                -- Ask for user's input here
                DBMS_OUTPUT_PUT_LINE('-- Recommended Process:');
                DBMS_OUTPUT_PUT_LINE('--SHUTDOWN IMMEDIATE;');
                DBMS_OUTPUT_PUT_LINE('--STARTUP MOUNT;');
                DBMS_OUTPUT_PUT_LINE('--ALTER DATABASE ARCHIVELOG;');
                DBMS_OUTPUT_PUT_LINE('--ALTER DATABASE OPEN;');
            end if;
            DBMS_OUTPUT_PUT_LINE('--');
        end if;
    end if;

    --------------------------------------
    ---  Global names
    --------------------------------------
    if c_is_db_rds_allocated = 'NO' then
        if v_global_names != 'FALSE' then
            DBMS_OUTPUT_PUT_LINE('-- Database '||v_db_name||' GLOBAL_NAMES is enabled, alter database is required.');
            DBMS_OUTPUT_PUT_LINE('--');
            DBMS_OUTPUT_PUT_LINE('-- Property            Description');
            DBMS_OUTPUT_PUT_LINE('-- Parameter type      Boolean');
            DBMS_OUTPUT_PUT_LINE('-- Default value       false');
            DBMS_OUTPUT_PUT_LINE('-- Modifiable          ALTER SESSION, ALTER SYSTEM');
            DBMS_OUTPUT_PUT_LINE('-- Modifiable in a PDB Yes');
            DBMS_OUTPUT_PUT_LINE('-- Range of values     true | false');
            DBMS_OUTPUT_PUT_LINE('-- Basic               No');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('-- GLOBAL_NAMES specifies whether a database link is required to have the same   ');
            DBMS_OUTPUT_PUT_LINE('-- name as the database to which it connects.');
            DBMS_OUTPUT_PUT_LINE('-- If the value of GLOBAL_NAMES is false, then no check is performed. If you use ');
            DBMS_OUTPUT_PUT_LINE('-- use or plan to use distributed processing, then Oracle recommends that you set');
            DBMS_OUTPUT_PUT_LINE('-- set this parameter to true to ensure the use of consistent naming conventions ');
            DBMS_OUTPUT_PUT_LINE('-- for databases and links in a networked environment.');
            DBMS_OUTPUT_PUT_LINE('-- Oracle DMS recommends global_names to be set at false');
            DBMS_OUTPUT_PUT_LINE('--');
            DBMS_OUTPUT_PUT_LINE('ALTER SYSTEM SET GLOBAL_NAMES=FALSE;');
        else
            DBMS_OUTPUT_PUT_LINE('-- Global_names is set to FALSE, NO action required. ');
        end if;
    end if;
    DBMS_OUTPUT_PUT_LINE('--');

    --------------------------------------
    ---  Stream pool size
    --------------------------------------
    if c_is_db_rds_allocated = 'NO' and c_is_target_db = 'NO' and v_is_autonomous = 'NO' then
        if (v_stream_pool_size = 0 or v_stream_pool_size < v_recommended_stream) then
            DBMS_OUTPUT_PUT_LINE('-- Database '||v_db_name||' STREAMS_POOL_SIZE current size is '||v_stream_pool_size||'Mb and it will be modified to '||v_recommended_stream||'Mb');
            DBMS_OUTPUT_PUT_LINE('-- The STREAMS_POOL_SIZE value helps determine the size of the Streams pool.');
            DBMS_OUTPUT_PUT_LINE('--');
            DBMS_OUTPUT_PUT_LINE('-- Property            Description');
            DBMS_OUTPUT_PUT_LINE('-- Parameter type      Big integer');
            DBMS_OUTPUT_PUT_LINE('-- Syntax              STREAMS_POOL_SIZE = integer [K | M | G]');
            DBMS_OUTPUT_PUT_LINE('-- Default value       0');
            DBMS_OUTPUT_PUT_LINE('-- Modifiable          ALTER SYSTEM');
            DBMS_OUTPUT_PUT_LINE('-- Modifiable in a PDB No');
            DBMS_OUTPUT_PUT_LINE('-- Range of values     Minimum: 0');
            DBMS_OUTPUT_PUT_LINE('--                     Maximum: operating system-dependent');
            DBMS_OUTPUT_PUT_LINE('-- Basic               No');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('-- Oracle''s Automatic Shared Memory Management feature manages the size of');
            DBMS_OUTPUT_PUT_LINE('-- the Streams pool when the SGA_TARGET initialization parameter is set to ');
            DBMS_OUTPUT_PUT_LINE('-- a nonzero value. If the STREAMS_POOL_SIZE initialization parameter also ');
            DBMS_OUTPUT_PUT_LINE('-- is set to a nonzero value, then Automatic Shared Memory Management uses ');
            DBMS_OUTPUT_PUT_LINE('-- this value as a minimum for the Streams pool.');
            DBMS_OUTPUT_PUT_LINE('-- Oracle Data Migration Service recommends streams_pool_size to be set at 2G at least.');
            DBMS_OUTPUT_PUT_LINE('--');
            DBMS_OUTPUT_PUT_LINE('ALTER SYSTEM SET STREAMS_POOL_SIZE='||v_recommended_stream||'M;');
            v_is_db_gg_ready := FALSE;
        else
            DBMS_OUTPUT_PUT_LINE('-- Stream pool size is already configured to '||v_stream_pool_size|| ', NO action required. ');
        end if;
        DBMS_OUTPUT_PUT_LINE('--');
    end if;

    --------------------------------------
    ---  Force Logging
    --------------------------------------
    if c_is_target_db = 'NO' and v_is_autonomous = 'NO' then
        if v_force_logging != 'YES' then
            if c_is_db_rds_allocated = 'YES' then
                DBMS_OUTPUT_PUT_LINE('-- Database '||v_db_name||' is not the recommended Force Logging Mode, turning on is required.');
            else
                DBMS_OUTPUT_PUT_LINE('-- Database '||v_db_name||' is not the recommended Force Logging Mode, alter database is required.');
            end if;
            DBMS_OUTPUT_PUT_LINE('--');
            DBMS_OUTPUT_PUT_LINE('-- Use this clause to put the database into or take the database out of FORCE LOGGING mode.');
            DBMS_OUTPUT_PUT_LINE('-- The database must be mounted or open.');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('-- In FORCE LOGGING  mode, Oracle  Database logs all changes in  the database  except changes in temporary');
            DBMS_OUTPUT_PUT_LINE('-- tablespaces  and  temporary segments.  This setting  takes  precedence  over and is  independent of any');
            DBMS_OUTPUT_PUT_LINE('-- NOLOGGING or FORCE LOGGING settings you  specify for individual tablespaces  and any NOLOGGING settings');
            DBMS_OUTPUT_PUT_LINE('-- you specify for individual database objects.');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('-- If you specify FORCE LOGGING, then Oracle Database waits for all ongoing unlogged operations to finish.');
            DBMS_OUTPUT_PUT_LINE('--');
            if c_is_db_rds_allocated = 'YES' then
                DBMS_OUTPUT_PUT_LINE('EXEC RDSADMIN.RDSADMIN_UTIL.FORCE_LOGGING(P_ENABLE => TRUE);');
            else
                DBMS_OUTPUT_PUT_LINE('ALTER DATABASE FORCE LOGGING;');
            end if;
            v_is_db_gg_ready := FALSE;
        else
            DBMS_OUTPUT_PUT_LINE('-- Database '||v_db_name||' is in the required FORCE LOGGING mode, NO action required.');
        end if;
        DBMS_OUTPUT_PUT_LINE('--');
    end if;

    --------------------------------------
    ---  Enable GoldenGate
    --------------------------------------
    if c_is_db_rds_allocated = 'NO' and v_is_autonomous = 'NO' then
        if (c_is_online_mig = 'YES' and v_enable_ogg_rep != 'TRUE') then
            DBMS_OUTPUT_PUT_LINE('-- Database '||v_db_name||' GoldenGate Parameter is not ENABLED, alter database is required');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('-- Property             Description');
            DBMS_OUTPUT_PUT_LINE('-- Parameter type       Boolean');
            DBMS_OUTPUT_PUT_LINE('-- Default value        false');
            DBMS_OUTPUT_PUT_LINE('-- Modifiable           ALTER SYSTEM');
            DBMS_OUTPUT_PUT_LINE('-- Modifiable in a PDB  No');
            DBMS_OUTPUT_PUT_LINE('-- Range of values      true | false');
            DBMS_OUTPUT_PUT_LINE('-- Basic                No');
            DBMS_OUTPUT_PUT_LINE('-- Oracle RAC All       instances must have the same setting');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('-- This parameter primarily  controls supplemental logging required to support logical replication of');
            DBMS_OUTPUT_PUT_LINE('-- new data types and operations. The redo log file is  designed to be  applied physically to a data-');
            DBMS_OUTPUT_PUT_LINE('-- base, therefore the  default contents of the  redo log file often do not contain sufficient infor-');
            DBMS_OUTPUT_PUT_LINE('-- mation to  allow logged  changes to be  converted into  SQL statements.  Supplemental logging adds');
            DBMS_OUTPUT_PUT_LINE('-- extra information into the redo log files so that  replication can convert logged changes into SQL');
            DBMS_OUTPUT_PUT_LINE('-- statements without  having to access the database for each change.  Previously these extra changes');
            DBMS_OUTPUT_PUT_LINE('-- were controlled by the  supplemental logging DDL.  Now the ENABLE_GOLDENGATE_REPLICATION parameter');
            DBMS_OUTPUT_PUT_LINE('-- must also be set to enable the required supplemental logging for any new data types or operations.');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('ALTER SYSTEM SET ENABLE_GOLDENGATE_REPLICATION=TRUE SCOPE=BOTH;');
            v_is_db_gg_ready := FALSE;
        else
            DBMS_OUTPUT_PUT_LINE('-- Database '||v_db_name||' GoldenGate Parameter is ENABLED, NO action required.');
        end if;
        DBMS_OUTPUT_PUT_LINE('--');
    end if;

    --------------------------------------
    ---  Supplemental Logging
    --------------------------------------
    if c_is_target_db = 'NO' then
        if v_supplemental != 'YES' then
            DBMS_OUTPUT_PUT_LINE('-- Database '||v_db_name||' does not have SUPPLEMENTAL LOGGING enabled and an alter database is required.');
            if c_is_db_rds_allocated = 'YES' then
                DBMS_OUTPUT_PUT_LINE('EXEC RDSADMIN.RDSADMIN_UTIL.ALTER_SUPPLEMENTAL_LOGGING(''ADD'');');
            else
                DBMS_OUTPUT_PUT_LINE('ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;');
            end if;
            v_is_db_gg_ready := FALSE;
        else
            DBMS_OUTPUT_PUT_LINE('-- Database '||v_db_name||' has SUPPLEMENTAL LOGGING enabled, NO action required.');
        end if;
        DBMS_OUTPUT_PUT_LINE('--');
    end if;


    --------------------------------------------------------------------
    ---  Initial load user for Datapump (required for the migration)
    --------------------------------------------------------------------
    if c_is_db_rds_allocated = 'NO' and v_initial_load_usr_exists = 'YES' then
        if v_is_initial_load_usr_locked = 'YES' and upper(c_initial_load_user) != c_ggadmin_user then
            DBMS_OUTPUT_PUT_LINE('-- User '||c_initial_load_user||' (Initial Load User) from database '||v_db_name||' is locked, alter user account unlock is required.');
            DBMS_OUTPUT_PUT_LINE('--');
            DBMS_OUTPUT_PUT_LINE('-- For the migration, a user that has the DATAPUMP_EXP_FULL_DATABASE role is required for the');
            DBMS_OUTPUT_PUT_LINE('-- export operation at the source database.  This user is  selected as database administrator');
            DBMS_OUTPUT_PUT_LINE('-- when you create  Database Connections with the source databases.  Oracle DMS recommends to');
            DBMS_OUTPUT_PUT_LINE('-- utilize the system user.');
            DBMS_OUTPUT_PUT_LINE('--');
            if c_is_multitenant = 'YES' then
                if v_initial_load_usr_in_pdb = 'YES' then
                    DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = '||v_pdb_name||';');
                    DBMS_OUTPUT_PUT_LINE('ALTER USER '||c_initial_load_user||' IDENTIFIED BY "'||c_initial_load_pwd||'" ACCOUNT UNLOCK CONTAINER=CURRENT;');
                else
                    DBMS_OUTPUT_PUT_LINE('ALTER USER '||c_initial_load_user||' IDENTIFIED BY "'||c_initial_load_pwd||'" ACCOUNT UNLOCK CONTAINER=ALL;');
                end if;
            else
                DBMS_OUTPUT_PUT_LINE('ALTER USER '||c_initial_load_user||' IDENTIFIED BY "'||c_initial_load_pwd||'" ACCOUNT UNLOCK;');
            end if;
            DBMS_OUTPUT_PUT_LINE('--');
        else
            DBMS_OUTPUT_PUT_LINE('-- User '||c_initial_load_user||' (Initial Load User) from database '||v_db_name||' is unlocked, NO action required.');
            DBMS_OUTPUT_PUT_LINE('--');
        end if;

        -- Privileges for initial load user when it's different from replication user
        if upper(c_initial_load_user) != c_ggadmin_user then
            DBMS_OUTPUT_PUT_LINE('--');
            DBMS_OUTPUT_PUT_LINE('--###########################################################');
            DBMS_OUTPUT_PUT_LINE('--#### Privileges to be granted to the Initial Load user ####');
            DBMS_OUTPUT_PUT_LINE('--###########################################################');
            DBMS_OUTPUT_PUT_LINE('--');

            if v_initial_load_usr_in_pdb = 'YES' then
                DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = '||v_pdb_name||';');

                -- Check if the Local Initial Load user already have each Privilege required
                v_sql_text :=
                    'select granted_role as granted_privs from cdb_role_privs where grantee='''||c_initial_load_user||''' and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||'''))
                    union
                    select privilege as granted_privs from cdb_sys_privs where grantee='''||c_initial_load_user||''' and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||''')) order by 1';
                check_current_grants(v_sql_text, v_initial_load_privs, c_initial_load_user, 'CURRENT');

                DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = CDB\$ROOT;');
            else
                -- Check if the Global Initial Load user already have each Privilege required
                v_sql_text :=
                   'select granted_role as granted_privs from dba_role_privs where grantee='''||c_initial_load_user||'''
                    union
                    select privilege as granted_privs from dba_sys_privs where grantee='''||c_initial_load_user||''' order by 1';
                if c_is_multitenant = 'YES' then
                    check_current_grants(v_sql_text, v_initial_load_privs, c_initial_load_user, 'ALL');
                else
                    check_current_grants(v_sql_text, v_initial_load_privs, c_initial_load_user, 'NONE');
                end if;
            end if;
            DBMS_OUTPUT_PUT_LINE('--');
        end if;

        -- If db version is prior 12.1.0.2 grant execution on dbms_system package to system user.
        if v_is_db_ver_prior_12_1_0_2 = 'YES' then
            DBMS_OUTPUT_PUT_LINE('-- Version of database '||v_db_name||' is '||v_db_version_full||', grant on DBMS_SYSTEM package ');
            DBMS_OUTPUT_PUT_LINE('-- to '||c_initial_load_user||' user is required.');
            DBMS_OUTPUT_PUT_LINE('CREATE PUBLIC SYNONYM dbms_system FOR dbms_system;');
            DBMS_OUTPUT_PUT_LINE('GRANT EXECUTE ON dbms_system TO '||c_initial_load_user||';');
            DBMS_OUTPUT_PUT_LINE('--');
        end if;

    end if;

    ----------------------------------------------------------------------------
    ---  Job Queue Processes (for multitenant databases in online migrations)
    ----------------------------------------------------------------------------
    if c_is_online_mig = 'YES' and c_is_db_rds_allocated = 'NO' and c_is_multitenant = 'YES' and v_is_autonomous = 'NO' then
        -- Just update the JOB_QUEUE_PROCESSES parameter value if it is not set to the minimum acceptable
        if v_job_queue_processes_cdb < v_job_queue_proc_min_cdb or v_job_queue_processes_pdb < v_job_queue_proc_min_pdb then
            DBMS_OUTPUT_PUT_LINE('-- Database '||v_db_name||' JOB_QUEUE_PROCESSES Parameter value is '||v_job_queue_processes_cdb||' in the root container');
            DBMS_OUTPUT_PUT_LINE('-- and '||v_job_queue_processes_pdb||' in the PDB container ('||v_pdb_name||'), alter database is required.');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('-- Property             Description');
            DBMS_OUTPUT_PUT_LINE('-- Parameter type       Integer');
            DBMS_OUTPUT_PUT_LINE('-- Default value        Derived. The lesser value of: (1) CPU_COUNT * 20,  (2) SESSIONS / 4. If the');
            DBMS_OUTPUT_PUT_LINE('--                      result of  the previous derivation is  less than twice  the number of  open');
            DBMS_OUTPUT_PUT_LINE('--                      containers in  the CDB,  then the value of  this parameter is  adjusted  to');
            DBMS_OUTPUT_PUT_LINE('--                      equal  twice the number of open containers  in the CDB.  Containers include');
            DBMS_OUTPUT_PUT_LINE('--                      CDB\$ROOT, PDB\$SEED, PDBs,  application roots, application seeds, and appli-');
            DBMS_OUTPUT_PUT_LINE('--                      cation PDBs.');
            DBMS_OUTPUT_PUT_LINE('-- Modifiable           ALTER SYSTEM');
            DBMS_OUTPUT_PUT_LINE('-- Modifiable in a PDB  Yes');
            DBMS_OUTPUT_PUT_LINE('-- Range of values      0 to 4000');
            DBMS_OUTPUT_PUT_LINE('-- Basic                No');
            DBMS_OUTPUT_PUT_LINE('-- Oracle RAC All       Multiple instances can have different values.');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('-- This parameter specifies  the maximum number of job slaves per instance  that can be created for');
            DBMS_OUTPUT_PUT_LINE('-- the execution of DBMS_JOB jobs and Oracle Scheduler (DBMS_SCHEDULER) jobs.  DBMS_JOB and  Oracle');
            DBMS_OUTPUT_PUT_LINE('-- Scheduler  share the same  job coordinator and  job slaves, and they are both  controlled by the');
            DBMS_OUTPUT_PUT_LINE('-- JOB_QUEUE_PROCESSES parameter. The actual number of job slaves created for Oracle Scheduler jobs');
            DBMS_OUTPUT_PUT_LINE('-- is auto-tuned by the  Scheduler depending on several factors, including available resources, Re-');
            DBMS_OUTPUT_PUT_LINE('-- source Manager settings,  and currently running jobs.  However, the combined total number of job');
            DBMS_OUTPUT_PUT_LINE('-- slaves running  DBMS_JOB jobs and  Oracle Scheduler jobs  in a non-CDB,  CDB, or  PDB can  never');
            DBMS_OUTPUT_PUT_LINE('-- exceed the value of JOB_QUEUE_PROCESSES for that non-CDB, CDB, or PDB.');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('-- The default value for  JOB_QUEUE_PROCESSES  provides a compromise between quality of service for');
            DBMS_OUTPUT_PUT_LINE('-- applications and  reasonable use of system resources.  However, it is possible that  the default');
            DBMS_OUTPUT_PUT_LINE('-- value  does not suit every environment.  In such cases, you can use the following  guidelines to');
            DBMS_OUTPUT_PUT_LINE('-- fine tune this parameter: ');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('-- In a non-CDB:');
            DBMS_OUTPUT_PUT_LINE('-- Set JOB_QUEUE_PROCESSES to the  maximum number  of job slaves that can be used simultaneously in');
            DBMS_OUTPUT_PUT_LINE('-- the  entire  database  instance.  If  JOB_QUEUE_PROCESSES  is 0,  then DBMS_JOB  jobs and Oracle');
            DBMS_OUTPUT_PUT_LINE('-- Scheduler jobs will not run in the database instance. ');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('-- In a CDB root:');
            DBMS_OUTPUT_PUT_LINE('-- Set JOB_QUEUE_PROCESSES to the  maximum number of job slaves that can be  used simultaneously in');
            DBMS_OUTPUT_PUT_LINE('-- the entire CDB. Oracle recommends that you set the value of this parameter to at least twice the');
            DBMS_OUTPUT_PUT_LINE('-- number of open containers in the CDB, otherwise,  there might be severe starvation  between PDBs');
            DBMS_OUTPUT_PUT_LINE('-- trying to run multiple jobs. If JOB_QUEUE_PROCESSES is set to 0 in a CDB root, then DBMS_JOB and');
            DBMS_OUTPUT_PUT_LINE('-- Oracle  Scheduler  jobs  cannot  run  in  the  CDB  root  or  in  any  PDB,  regardless  of  the');
            DBMS_OUTPUT_PUT_LINE('-- JOB_QUEUE_PROCESSES setting at the PDB level. ');
            DBMS_OUTPUT_PUT_LINE('-- ');
            DBMS_OUTPUT_PUT_LINE('-- In a PDB:');
            DBMS_OUTPUT_PUT_LINE('-- Set JOB_QUEUE_PROCESSES to the maximum  number of job slaves that can be used  simultaneously in');
            DBMS_OUTPUT_PUT_LINE('-- the PDB.  The actual number depends on the resources assigned by Resource Manager and the demand');
            DBMS_OUTPUT_PUT_LINE('-- in other containers. When multiple PDBs request jobs, Oracle Scheduler attempts to give all PDBs');
            DBMS_OUTPUT_PUT_LINE('-- a fair share of the processes.  Oracle recommends that you set the value of this parameter to at');
            DBMS_OUTPUT_PUT_LINE('-- least 2 in a PDB.');
            DBMS_OUTPUT_PUT_LINE('-- ');

            if v_job_queue_processes_cdb < v_job_queue_proc_min_cdb then
                DBMS_OUTPUT_PUT_LINE('ALTER SYSTEM SET JOB_QUEUE_PROCESSES = '||v_job_queue_proc_min_cdb||' SCOPE=BOTH;');
            end if;

            if v_job_queue_processes_pdb < v_job_queue_proc_min_pdb then
                DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = '||v_pdb_name||';');
                DBMS_OUTPUT_PUT_LINE('ALTER SYSTEM SET JOB_QUEUE_PROCESSES = '||v_job_queue_proc_min_pdb||' SCOPE=BOTH;');
                DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = CDB\$ROOT;');
            end if;
        end if;
    end if;


    ----------------------------------------------------
    --  If it's an Online Migration,
    --  Create GoldenGate User(s) if it does not exist
    ----------------------------------------------------
    DBMS_OUTPUT_PUT_LINE('--');
    if c_is_online_mig = 'YES' then
        if c_is_db_rds_allocated = 'NO' and c_is_multitenant = 'YES' and v_is_autonomous = 'NO' then

            -- Create user CDB
            if c_is_target_db = 'NO' then
                if v_cdb_user = 'NO' then
                    DBMS_OUTPUT_PUT_LINE('--######################################################');
                    DBMS_OUTPUT_PUT_LINE('--#### Create and Grant Privileges to the CDB user. ####');
                    DBMS_OUTPUT_PUT_LINE('--######################################################');
                    DBMS_OUTPUT_PUT_LINE('--');
                    DBMS_OUTPUT_PUT_LINE('-- GoldenGate CDB User does not exist, create CDB user is required to extract transactions from the database.');
                    DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = CDB\$ROOT;');
                    DBMS_OUTPUT_PUT_LINE('CREATE USER '||c_cdb_user||' IDENTIFIED BY "'||c_db_password||'" CONTAINER=ALL DEFAULT TABLESPACE USERS TEMPORARY TABLESPACE TEMP QUOTA UNLIMITED ON USERS;');
                    v_is_db_gg_ready := FALSE;
                elsif v_is_cdb_usr_locked = 'YES' then
                    DBMS_OUTPUT_PUT_LINE('--######################################################');
                    DBMS_OUTPUT_PUT_LINE('--#### Unlock and Grant Privileges to the CDB user. ####');
                    DBMS_OUTPUT_PUT_LINE('--######################################################');
                    DBMS_OUTPUT_PUT_LINE('--');
                    DBMS_OUTPUT_PUT_LINE('-- CDB User already exists but is locked, alter user account unlock required.');
                    DBMS_OUTPUT_PUT_LINE('--');
                    DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = CDB\$ROOT;');
                    DBMS_OUTPUT_PUT_LINE('ALTER USER '||c_cdb_user||' IDENTIFIED BY "'||c_db_password||'" ACCOUNT UNLOCK CONTAINER=ALL DEFAULT TABLESPACE USERS TEMPORARY TABLESPACE TEMP QUOTA UNLIMITED ON USERS;');
                else
                    DBMS_OUTPUT_PUT_LINE('-- CDB User already exists, NO action required.');
                    DBMS_OUTPUT_PUT_LINE('--');
                    DBMS_OUTPUT_PUT_LINE('--######################################################');
                    DBMS_OUTPUT_PUT_LINE('--####   Privileges to be granted to the CDB user.  ####');
                    DBMS_OUTPUT_PUT_LINE('--######################################################');
                    DBMS_OUTPUT_PUT_LINE('--');
                    DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = CDB\$ROOT;');
                end if;
                DBMS_OUTPUT_PUT_LINE('--');

                -- ####### Check if the CDB user already have each Privilege required to
                -- ####### enable GoldenGate
                v_sql_text :=
                   'select granted_role as granted_privs from dba_role_privs where grantee='''||c_cdb_user||'''
                    union
                    select privilege as granted_privs from dba_sys_privs where grantee='''||c_cdb_user||''' order by 1';
                check_current_grants(v_sql_text, v_cdb_privs, c_cdb_user, 'ALL');

                --  Check the DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE package has been executed and execute if it's not
                select decode(count(*),1,'YES','NO') into v_cdb_package_executed
                from
                (select username from DBA_GOLDENGATE_PRIVILEGES
                    where dba_goldengate_privileges.grant_select_privileges = 'YES'
                    and dba_goldengate_privileges.privilege_type = '*'
                    and upper(dba_goldengate_privileges.username) = upper(c_cdb_user)
                union all
                select grantee username from DBA_ROLE_PRIVS
                    where dba_role_privs.granted_role in ('OGG_CAPTURE', 'OGG_APPLY')
                    and upper(dba_role_privs.grantee) = upper(c_cdb_user));

                if v_cdb_package_executed = 'NO' then
                    if to_number(v_db_version) >= 23 then
                        DBMS_OUTPUT_PUT_LINE('GRANT OGG_CAPTURE, OGG_APPLY to '||c_cdb_user||' CONTAINER=ALL;');
                    else
                        DBMS_OUTPUT_PUT_LINE('EXEC DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE('''||c_cdb_user||''',CONTAINER=>''ALL'');');
                    end if;
                end if;
                DBMS_OUTPUT_PUT_LINE('--');

            end if;

            -- Create User PDB
            if v_pdb_user = 'NO' then
                DBMS_OUTPUT_PUT_LINE('--######################################################');
                DBMS_OUTPUT_PUT_LINE('--#### Create and Grant Privileges to the PDB user. ####');
                DBMS_OUTPUT_PUT_LINE('--######################################################');
                DBMS_OUTPUT_PUT_LINE('--');
                DBMS_OUTPUT_PUT_LINE('-- GoldenGate PDB User does not exist, create PDB user is required to extract transactions from the database.');
                DBMS_OUTPUT_PUT_LINE('--');
                DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = '||v_pdb_name||';');
                if v_pdb_tablespace = 'NO' then
                   create_tablespace('PDB');
                end if;
                DBMS_OUTPUT_PUT_LINE('CREATE USER '||c_pdb_user||' IDENTIFIED BY "'||c_db_password||'" CONTAINER=CURRENT DEFAULT TABLESPACE '
                    ||c_ogg_tablespace||' TEMPORARY TABLESPACE TEMP QUOTA UNLIMITED ON '||c_ogg_tablespace||';');
                v_is_db_gg_ready := FALSE;

            elsif v_is_pdb_usr_locked = 'YES' then
                DBMS_OUTPUT_PUT_LINE('--######################################################');
                DBMS_OUTPUT_PUT_LINE('--#### Unlock and Grant Privileges to the PDB user. ####');
                DBMS_OUTPUT_PUT_LINE('--######################################################');
                DBMS_OUTPUT_PUT_LINE('--');
                DBMS_OUTPUT_PUT_LINE('-- PDB User already exists but is locked, alter user account unlock required.');
                DBMS_OUTPUT_PUT_LINE('--');
                DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = '||v_pdb_name||';');
                if v_pdb_tablespace = 'NO' then
                   create_tablespace('PDB');
                end if;
                DBMS_OUTPUT_PUT_LINE('ALTER USER '||c_pdb_user||' IDENTIFIED BY "'||c_db_password||'" ACCOUNT UNLOCK CONTAINER=CURRENT DEFAULT TABLESPACE '
                    ||c_ogg_tablespace||' TEMPORARY TABLESPACE TEMP QUOTA UNLIMITED ON '||c_ogg_tablespace||';');
            else
                DBMS_OUTPUT_PUT_LINE('-- PDB User already exists, NO action required.');
                DBMS_OUTPUT_PUT_LINE('--');
                DBMS_OUTPUT_PUT_LINE('--######################################################');
                DBMS_OUTPUT_PUT_LINE('--####   Privileges to be granted to the PDB user.  ####');
                DBMS_OUTPUT_PUT_LINE('--######################################################');
                DBMS_OUTPUT_PUT_LINE('--');
                DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = '||v_pdb_name||';');
            end if;
            DBMS_OUTPUT_PUT_LINE('--');

            -- ####### Check if the PDB user already have each Privilege required to
            -- ####### enable GoldenGate
            v_sql_text :=
                'select granted_role as granted_privs from cdb_role_privs where grantee='''||c_pdb_user||''' and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||'''))
                union
                select privilege as granted_privs from cdb_sys_privs where grantee='''||c_pdb_user||''' and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||''')) order by 1';
            check_current_grants(v_sql_text, v_pdb_privs, c_pdb_user, 'CURRENT');

            --  Check the DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE package has been executed and execute if it's not
            EXECUTE IMMEDIATE(
            'select decode(count(*),1,''YES'',''NO'')
            from
            (select username from CDB_GOLDENGATE_PRIVILEGES
                where cdb_goldengate_privileges.grant_select_privileges = ''YES''
                and cdb_goldengate_privileges.privilege_type = ''*''
                and upper(cdb_goldengate_privileges.username) = upper('''||c_pdb_user||''')
            union all
            select grantee username from dba_ROLE_PRIVS
                where dba_role_privs.granted_role in (''OGG_CAPTURE'', ''OGG_APPLY'')
                and upper(dba_role_privs.grantee) = upper('''||c_pdb_user||'''))') INTO v_pdb_package_executed;

            if v_pdb_package_executed = 'NO' then
                if to_number(v_db_version) >= 23 then
                    DBMS_OUTPUT_PUT_LINE('GRANT OGG_CAPTURE, OGG_APPLY to '||c_pdb_user||' CONTAINER=CURRENT;');
                else
                    DBMS_OUTPUT_PUT_LINE('EXEC DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE('''||c_pdb_user||''',CONTAINER=>''CURRENT'');');
                end if;
                v_is_db_gg_ready := FALSE;
            end if;
            DBMS_OUTPUT_PUT_LINE('--');
            -- End create user PDB

        else
            -- Create User NonCDB
            if v_noncdb_user = 'NO' then
                DBMS_OUTPUT_PUT_LINE('--#########################################################');
                DBMS_OUTPUT_PUT_LINE('--#### Create and Grant Privileges to the NonCDB user. ####');
                DBMS_OUTPUT_PUT_LINE('--#########################################################' );
                DBMS_OUTPUT_PUT_LINE('--');
                DBMS_OUTPUT_PUT_LINE('-- GoldenGate User does not exist, create NonCDB user is required to extract transactions from the database.');
                DBMS_OUTPUT_PUT_LINE('--');
                if v_pdb_name is not null then
                    DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = '||v_pdb_name||';');
                end if;
                if c_is_db_rds_allocated = 'YES' then
                    DBMS_OUTPUT_PUT_LINE('CREATE USER '||c_noncdb_user||' IDENTIFIED BY "'||c_db_password||'" DEFAULT TABLESPACE USERS'
                        ||' TEMPORARY TABLESPACE TEMP QUOTA 100M ON USERS;');
                else
                    if v_noncdb_tablespace = 'NO' then
                        create_tablespace('nonCDB');
                    end if;
                    DBMS_OUTPUT_PUT_LINE('CREATE USER '||c_noncdb_user||' IDENTIFIED BY "'||c_db_password||'" DEFAULT TABLESPACE '
                        ||c_ogg_tablespace||' TEMPORARY TABLESPACE TEMP QUOTA UNLIMITED ON '||c_ogg_tablespace||';');
                end if;
            elsif v_is_noncdb_usr_locked = 'YES' then
                DBMS_OUTPUT_PUT_LINE('--##########################################################');
                DBMS_OUTPUT_PUT_LINE('--#### Unlock and Grant Privileges to the NonCDB user. ####');
                DBMS_OUTPUT_PUT_LINE('--##########################################################');
                DBMS_OUTPUT_PUT_LINE('--');
                DBMS_OUTPUT_PUT_LINE('-- GoldenGate User already exists but is locked, alter user required.');
                DBMS_OUTPUT_PUT_LINE('--');
                if v_pdb_name is not null then
                    DBMS_OUTPUT_PUT_LINE('ALTER SESSION SET CONTAINER = '||v_pdb_name||';');
                end if;
                if c_is_db_rds_allocated = 'YES' then
                    DBMS_OUTPUT_PUT_LINE('ALTER USER '||c_noncdb_user||' IDENTIFIED BY "'||c_db_password||'" ACCOUNT UNLOCK DEFAULT TABLESPACE USERS'
                        ||' TEMPORARY TABLESPACE TEMP QUOTA 100M ON USERS;');
                else
                    DBMS_OUTPUT_PUT_LINE('ALTER USER '||c_noncdb_user||' IDENTIFIED BY "'||c_db_password||'" ACCOUNT UNLOCK;');
                end if;
            else
                DBMS_OUTPUT_PUT_LINE('-- GoldenGate User already exists, NO action required.');
            end if;
            DBMS_OUTPUT_PUT_LINE('--');

            -- ####### nonCDB Privileges

            if c_is_db_rds_allocated = 'YES' then
                DBMS_OUTPUT_PUT_LINE('--##########################################################');
                DBMS_OUTPUT_PUT_LINE('--#### Privileges to be granted to the RDS NonCDB user. ####');
                DBMS_OUTPUT_PUT_LINE('--##########################################################');
                DBMS_OUTPUT_PUT_LINE('--');

                -- Privileges for nonCDB RDS user.
                v_sql_text :=
                    'select granted_role as granted_privs from dba_role_privs where grantee='''||c_noncdb_user||'''
                    union
                    select privilege as granted_privs from dba_sys_privs where grantee='''||c_noncdb_user||'''
                    union
                    select privilege || '' ON '' || owner || ''.'' || table_name as granted_privs from dba_tab_privs where grantee = '''||c_noncdb_user||'''
                    order by 1';
                check_current_grants(v_sql_text, v_noncdb_rds_privs, c_noncdb_user, 'NONE', TRUE);

                --  Check the DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE package has been executed and execute if it's not
                select decode(count(*),1,'YES','NO') into v_noncdb_package_executed
                from
                (select username from DBA_GOLDENGATE_PRIVILEGES
                    where dba_goldengate_privileges.grant_select_privileges = 'YES'
                    and dba_goldengate_privileges.privilege_type = '*'
                    and upper(dba_goldengate_privileges.username) = upper(c_noncdb_user)
                union all
                select grantee username from DBA_ROLE_PRIVS
                    where dba_role_privs.granted_role in ('OGG_CAPTURE', 'OGG_APPLY')
                    and upper(dba_role_privs.grantee) = upper(c_noncdb_user));

                if v_noncdb_package_executed = 'NO' then
                    DBMS_OUTPUT_PUT_LINE('EXEC RDSADMIN.RDSADMIN_DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE'
                                                    ||'(GRANTEE=>'''||c_noncdb_user||''','
                                                    ||'PRIVILEGE_TYPE=>''CAPTURE'','
                                                    ||'GRANT_SELECT_PRIVILEGES=>TRUE,'
                                                    ||'DO_GRANTS=>TRUE);');
                else
                    DBMS_OUTPUT_PUT_LINE('-- Package RDSADMIN.RDSADMIN_DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE already executed for '||c_noncdb_user);
                end if;

                DBMS_OUTPUT_PUT_LINE('---');


            elsif v_is_autonomous = 'NO' then
                DBMS_OUTPUT_PUT_LINE('--######################################################');
                DBMS_OUTPUT_PUT_LINE('--#### Privileges to be granted to the NonCDB user. ####');
                DBMS_OUTPUT_PUT_LINE('--######################################################');
                DBMS_OUTPUT_PUT_LINE('--');

                -- ####### Check if the NonCDB user already have each Privilege required to
                -- ####### enable GoldenGate
                v_sql_text :=
                    'select granted_role as granted_privs from dba_role_privs where grantee='''||c_noncdb_user||'''
                    union
                    select privilege as granted_privs from dba_sys_privs where grantee='''||c_noncdb_user||''' order by 1';
                check_current_grants(v_sql_text, v_pdb_privs, c_noncdb_user, 'NONE');

                --  Check the DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE package has been executed and execute if it's not
                select decode(count(*),1,'YES','NO') into v_noncdb_package_executed
                from
                (select username from DBA_GOLDENGATE_PRIVILEGES
                    where dba_goldengate_privileges.grant_select_privileges = 'YES'
                    and dba_goldengate_privileges.privilege_type = '*'
                    and upper(dba_goldengate_privileges.username) = upper(c_noncdb_user)
                union all
                select grantee username from DBA_ROLE_PRIVS
                    where dba_role_privs.granted_role in ('OGG_CAPTURE', 'OGG_APPLY')
                    and upper(dba_role_privs.grantee) = upper(c_noncdb_user));

                if v_noncdb_package_executed = 'NO' then
                    if to_number(v_db_version) >= 23 then
                        DBMS_OUTPUT_PUT_LINE('GRANT OGG_CAPTURE, OGG_APPLY to '||c_pdb_user||';');
                    else
                        DBMS_OUTPUT_PUT_LINE('EXEC DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE('''||c_noncdb_user||''');');
                    end if;
                end if;
                DBMS_OUTPUT_PUT_LINE('---');
            -- End of Privileges for the NonCDB user if non Autonomous

            else -- Privileges for NonCDB user if Autonomous
                DBMS_OUTPUT_PUT_LINE('--##########################################################');
                DBMS_OUTPUT_PUT_LINE('--#### Privileges to be granted to the GoldenGate user. ####');
                DBMS_OUTPUT_PUT_LINE('--##########################################################');
                DBMS_OUTPUT_PUT_LINE('--');

                -- Check if PDB_DBA role is granted
                select decode(count(*),1,'YES','NO') into v_is_pdb_dba_role from dba_role_privs where grantee=c_noncdb_user and granted_role='PDB_DBA' and ADMIN_OPTION='YES';

                if v_is_pdb_dba_role = 'NO' then
                    DBMS_OUTPUT_PUT_LINE('GRANT PDB_DBA TO '||c_noncdb_user||' WITH ADMIN OPTION;');
                else
                    DBMS_OUTPUT_PUT_LINE('-- Role PDB_DBA with ADMIN option already granted TO '||c_noncdb_user);
                end if;

                -- ####### Check if the NonCDB user already have each Privilege required to
                -- ####### enable GoldenGate (Event Marker System)
                if c_is_target_db = 'NO' then
                    v_sql_text :=
                       'select granted_role as granted_privs from dba_role_privs where grantee='''||c_noncdb_user||'''
                        union
                        select privilege as granted_privs from dba_sys_privs where grantee='''||c_noncdb_user||'''
                        union
                        select a.privilege || '' ON '' || a.owner || ''.'' || a.table_name as granted_privs from dba_tab_privs a, dba_role_privs b
                        where b.grantee = '''||c_noncdb_user||''' and a.grantee = b.granted_role and a.owner = ''SYS'' and a.table_name like ''V\_\$%'' escape ''\''
                        order by 1';
                    check_current_grants(v_sql_text, v_adb_src_evnt_table_privs, c_noncdb_user, 'NONE');
                end if;

            end if;
        end if; -- Creation of GoldenGate users (CDB/PDB or nonCDB users)

        -- Prepare table for OGG Event Marker System, for Switchover phase
        if c_is_online_mig = 'YES' then
            -- Prepare ggadmin user in case the GoldenGate user is a different one
            if v_gg_user != c_ggadmin_user then
                if v_ggadmin_user = 'NO' then
                    DBMS_OUTPUT_PUT_LINE('--#########################################################');
                    DBMS_OUTPUT_PUT_LINE('--####              Create ggadmin user.               ####');
                    DBMS_OUTPUT_PUT_LINE('--#########################################################');
                    DBMS_OUTPUT_PUT_LINE('--');
                    DBMS_OUTPUT_PUT_LINE('-- GGADMIN User does not exist, create ggadmin user is necessary to prepare the database for the migration switchover phase.');
                    DBMS_OUTPUT_PUT_LINE('--');
                    DBMS_OUTPUT_PUT_LINE('CREATE USER '||c_ggadmin_user||' IDENTIFIED BY "'||c_db_password||'" DEFAULT TABLESPACE USERS'
                        ||' TEMPORARY TABLESPACE TEMP QUOTA 100M ON USERS;');
                elsif v_is_ggadmin_usr_locked = 'YES' then
                    DBMS_OUTPUT_PUT_LINE('--#########################################################');
                    DBMS_OUTPUT_PUT_LINE('--####              Unlock ggadmin user.               ####');
                    DBMS_OUTPUT_PUT_LINE('--#########################################################');
                    DBMS_OUTPUT_PUT_LINE('--');
                    DBMS_OUTPUT_PUT_LINE('-- GGADMIN User already exists but is locked, alter user required.');
                    DBMS_OUTPUT_PUT_LINE('-- This user is necessary to be unlocked in order to let the database be prepared for the migration switchover phase.');
                    DBMS_OUTPUT_PUT_LINE('--');
                    DBMS_OUTPUT_PUT_LINE('ALTER USER '||c_ggadmin_user||' IDENTIFIED BY "'||c_db_password||'" ACCOUNT UNLOCK;');
                    DBMS_OUTPUT_PUT_LINE('--');
                else
                    DBMS_OUTPUT_PUT_LINE('-- GGADMIN User already exists, NO action required.');
                    DBMS_OUTPUT_PUT_LINE('-- This user is utilized for the migration switchover phase.');
                    DBMS_OUTPUT_PUT_LINE('--');
                    DBMS_OUTPUT_PUT_LINE('--#######################################################');
                    DBMS_OUTPUT_PUT_LINE('--#### Privileges to be granted to the GGADMIN user. ####');
                    DBMS_OUTPUT_PUT_LINE('--#######################################################');
                    DBMS_OUTPUT_PUT_LINE('--');
                end if;

                -- Privileges for ggadmin user when it isn't the replication user
                if c_is_multitenant = 'YES' then
                    v_sql_text :=
                        'select granted_role as granted_privs from cdb_role_privs
                        where grantee='''||c_ggadmin_user||''' and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||'''))
                        union
                        select privilege as granted_privs from cdb_sys_privs
                        where grantee='''||c_ggadmin_user||''' and con_id = (select con_id from v\$pdbs where upper(name) = upper('''||v_pdb_name||''')) order by 1';
                    check_current_grants(v_sql_text, v_ggadmin_no_rep_privs, c_ggadmin_user, 'CURRENT');
                else
                    v_sql_text :=
                        'select granted_role as granted_privs from dba_role_privs
                        where grantee='''||c_ggadmin_user||'''
                        union
                        select privilege as granted_privs from dba_sys_privs
                        where grantee='''||c_ggadmin_user||''' order by 1';
                    check_current_grants(v_sql_text, v_ggadmin_no_rep_privs, c_ggadmin_user, 'NONE');
                end if;
            end if;
        end if; -- Preparation for switchover logic.

    end if; -- if online migration

    DBMS_OUTPUT_PUT_LINE('--');
    DBMS_OUTPUT_PUT_LINE('-- Script DMS_Configuration.sql generated. Please review this script, modify as appropriate and run it in your database.');
    if c_is_target_db = 'NO' then
        DBMS_OUTPUT_PUT_LINE('-- Your source database will be ready for migration after execution of these operations.');
    else
        DBMS_OUTPUT_PUT_LINE('-- Your target database will be ready for migration after execution of these operations.');
    end if;
    DBMS_OUTPUT_PUT_LINE('--');

    EXCEPTION
        WHEN c_user_abort_execution THEN
            DBMS_OUTPUT_PUT_LINE('ORA-30031: User aborted the execution!');
        WHEN c_cdb_user_invalid THEN
            dbms_output_put_line('ORA-20010: CDB User name must be entered!');
        WHEN c_pdb_user_invalid THEN
            dbms_output_put_line('ORA-20011: PDB User name must be entered!');
        WHEN c_initial_load_user_invalid THEN
            dbms_output_put_line('ORA-20012: Initial Load User name must be entered!');
        WHEN c_initial_load_user_not_exist THEN
            DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
            DBMS_OUTPUT_PUT_LINE('--          Database Error  ');
            DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
            DBMS_OUTPUT_PUT_LINE('--');
            dbms_output_put_line('ORA-20013: Initial Load User does not exist!');
        WHEN c_db_password_invalid THEN
            dbms_output_put_line('ORA-20014: PASSWORD must be entered!');
        WHEN c_initial_load_pwd_invalid THEN
            dbms_output_put_line('ORA-20015: PASSWORD for system user must be entered!');
        WHEN c_noncdb_user_invalid THEN
            dbms_output_put_line('ORA-20016: Non CDB User name must be entered!');
        WHEN c_pdb_service_name_invalid THEN
            DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
            DBMS_OUTPUT_PUT_LINE('--          Database Error  ');
            DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
            DBMS_OUTPUT_PUT_LINE('--');
            DBMS_OUTPUT_PUT_LINE('ORA-20017: The service name '''||upper(c_pdb_service_name)||''' you entered does not exist in the database. Review your SERVICE NAME and try again.');
        WHEN c_password_reused_exeption THEN
            DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
            DBMS_OUTPUT_PUT_LINE('--          Database Error  ');
            DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
            DBMS_OUTPUT_PUT_LINE('--');
            DBMS_OUTPUT_PUT_LINE('--Password for user system cannot be reused, please execute the dms-db-prep-v2.sh script again,');
            DBMS_OUTPUT_PUT_LINE('--provide a different password or choose not to update user system password, and try it again.');
            DBMS_OUTPUT_PUT_LINE('--');
            DBMS_OUTPUT_PUT_LINE('ORA-28007: The password cannot be reused');
        WHEN no_data_found THEN
            DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
            DBMS_OUTPUT_PUT_LINE('--          Database Error  ');
            DBMS_OUTPUT_PUT_LINE(rpad('--',90,'#'));
            DBMS_OUTPUT_PUT_LINE('--');
            DBMS_OUTPUT_PUT_LINE('ORA-20017: NO DATA FOUND, the service name '''||upper(c_pdb_service_name)||''' you entered does not exist in the database. Review your SERVICE NAME and try again.');
        WHEN TOO_MANY_ROWS then
            DBMS_OUTPUT_PUT_LINE('Error raised: '|| DBMS_UTILITY.FORMAT_ERROR_BACKTRACE || ' - '||sqlerrm);
            RAISE_APPLICATION_ERROR(-20002,'TOO MANY ROWS, Please Report to Oracle Support!');
END;
/

spool off
EOF
}
# end _dbPrepSqlScript_

_runSqlScriptInstructions_() {
    # DESC:
    #         Prints a message indicating to connect to a given database and run the generated sql script.
    # ARGS:
    #         Data base to connect, for example: 'source database', 'target CDB', etc.
    # OUTS:
    #         None
    # USAGE:
    #         _runSqlScriptInstructions_ 'source container database (CDB)'

    local _usertype="sysdba (role)";
    local _dbToConnectText="database";

    if [ $ISADB == 'YES' ]; then
      _usertype="admin"
    fi
    if [ $ISMULTITENANT == 'YES' ]; then
      _dbToConnectText="database's root container (CDB)"
    fi
    printf "Sql script ${bold}%s/%s${reset} generated.\n" "${PWD}" "${SQLSCRIPTNAME}"
    printf "Please connect to your %s as ${bold}%s${reset} and run the above generated sql script.\n" "${_dbToConnectText}" "${_usertype}"
    printf "This script will analyze your database and will generate a subsequent sql script that you must review, "
    printf "modify (if needed) and run in order to get your database set up for the migration."
    echo
    case ${SCRIPTTYPE} in
      "$SRC_OFFLINE_ADB")
          info 'When setting up your migration through the OCI Console: '
          info 'Use ggadmin user as the Initial Load Database Username when Creating a Database Connection for Source Database through the Database Migration Service'
          ;;
      "$SRC_OFFLINE_NONPDB" | "$SRC_OFFLINE_PDB")
          info 'When setting up your migration through the OCI Console: '
          info 'Use system user as the Initial Load Database Username when Creating a Database Connection for Source Database through the Database Migration Service'
          ;;
      "$SRC_OFFLINE_NONPDB_RDS")
          info 'In order to have your database prepared for the migration, please set the following parameters through the Parameter groups functionality:'
          info 'STREAMS_POOL_SIZE=2147483648'
          info 'GLOBAL_NAMES=FALSE'
          info 'To see how Parameter groups work please refer to https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/parameter-groups-overview.html'
          ;;
      "$SRC_ONLINE_NONPDB_RDS")
          info 'In order to have your database prepared for the migration, please set the following parameters through the Parameter groups functionality:'
          info 'STREAMS_POOL_SIZE=2147483648'
          info 'ENABLE_GOLDENGATE_REPLICATION=TRUE'
          info 'GLOBAL_NAMES=FALSE'
          info 'To see how Parameter groups work please refer to https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/parameter-groups-overview.html'
          info ' '
          info 'When setting up your migration through the OCI Console: '
          info 'Use ggadmin user as the GoldenGate Database User for Source Database when creating the Migration definition through the Database Migration Service'
          ;;
      "$SRC_ONLINE_ADB")
          info 'When setting up your migration through the OCI Console: '
          info 'Use ggadmin user as the Initial Load Database Username when Creating a Database Connection for Source Database through the Database Migration Service'
          info 'Use ggadmin user as the GoldenGate Database User for Source Database when creating the Migration definition through the Database Migration Service'
          ;;
      "$SRC_ONLINE_NONPDB")
          info 'When setting up your migration through the OCI Console: '
          info 'Use system user as the Initial Load Database Username when Creating a Database Connection for Source Database through the Database Migration Service'
          info 'Use ggadmin user as the GoldenGate Database User for Source Database when creating the Migration definition through the Database Migration Service'
          ;;
      "$SRC_ONLINE_PDB")
          info 'When setting up your migration through the OCI Console: '
          info 'Use system user as the Initial Load Database Username when Creating a Database Connection for Source Database through the Database Migration Service'
          info 'Create one Database Connection for the Container Database (CDB) and another one for the Plugable Database (PDB)'
          info 'Use ggadmin as the Replication Database Username for the Source Plugable Database when creating the Migration through the Database Migration Service'
          info 'Use c##ggadmin as the Replication Database Username for the Source Container Database when creating the Migration through the Database Migration Service'
          ;;
      "$TGT_OFFLINE_ATP")
          info 'When setting up your migration through the OCI Console: '
          info 'Use admin user as the Initial Load Database Username when Creating a Database Connection for Target Database through the Database Migration Service'
          ;;
      "$TGT_ONLINE_ATP" | "$TGT_ONLINE_NON_PDB")
          info 'When setting up your migration through the OCI Console: '
          info 'Use admin user as the Initial Load Database Username when Creating a Database Connection for Target Database through the Database Migration Service'
          info 'Use ggadmin user as the GoldenGate Database User for Target Database when creating the Migration through the Database Migration Service'
          ;;
      "$TGT_ONLINE_PDB")
          info 'When setting up your migration through the OCI Console: '
          info 'Use the Plugable Database (PDB) Connect String when Creating a Database Connection for Target Database through the Database Migration Service'
          info 'Use system user as the Initial Load Database Username when Creating a Database Connection for Target Database through the Database Migration Service'
          info 'Use ggadmin user as the Replication Database Username for Target Database when creating the Migration through the Database Migration Service'
          ;;
      "$TGT_OFFLINE_NON_PDB")
          info 'When setting up your migration through the OCI Console: '
          info 'Use system user as the Initial Load Database Username when Creating a Database Connection for Target Database through the Database Migration Service'
          ;;
      "$TGT_OFFLINE_PDB")
          info 'When setting up your migration through the OCI Console: '
          info 'Use the Plugable Database (PDB) Connect String when Creating a Database Connection for Target Database through the Database Migration Service'
          info 'Use system user as the Initial Load Database Username when Creating a Database Connection for Target Database through the Database Migration Service'
          ;;
      *)
          {
              error "Unrecognized options has been entered, please run this script again."
              # Exit cleanly
              _safeExit_
          }
          ;;
    esac
}
# end _runSqlScriptInstructions_

# ################################## Custom utility functions (Pasted from repository)

# ################################## Functions required for this template to work

_setColors_() {
    # DESC:
    #         Sets colors use for alerts.
    # ARGS:
    #         None
    # OUTS:
    #         None
    # USAGE:
    #         printf "%s\n" "${blue}Some text${reset}"

    if tput setaf 1 >/dev/null 2>&1; then
        bold=$(tput bold)
        underline=$(tput smul)
        reverse=$(tput rev)
        reset=$(tput sgr0)

        if [[ $(tput colors) -ge 256 ]] >/dev/null 2>&1; then
            white=$(tput setaf 231)
            blue=$(tput setaf 38)
            yellow=$(tput setaf 11)
            green=$(tput setaf 82)
            red=$(tput setaf 9)
            purple=$(tput setaf 171)
            gray=$(tput setaf 250)
        else
            white=$(tput setaf 7)
            blue=$(tput setaf 38)
            yellow=$(tput setaf 3)
            green=$(tput setaf 2)
            red=$(tput setaf 9)
            purple=$(tput setaf 13)
            gray=$(tput setaf 7)
        fi
    else
        bold="\033[4;37m"
        reset="\033[0m"
        underline="\033[4;37m"
        reverse=""
        white="\033[0;37m"
        # shellcheck disable=SC2034
        blue="\033[0;34m"
        yellow="\033[0;33m"
        green="\033[1;32m"
        red="\033[0;31m"
        purple="\033[0;35m"
        gray="\033[0;37m"
    fi
}

_alert_() {
    # DESC:
    #         Controls all printing of messages to log files and stdout.
    # ARGS:
    #         $1 (required) - The type of alert to print
    #                         (success, header, notice, debug, warning, error,
    #                         fatal, info, input)
    #         $2 (required) - The message to be printed to stdout and/or a log file
    #         $3 (optional) - Pass '${LINENO}' to print the line number where the _alert_ was triggered
    # OUTS:
    #         stdout: The message is printed to stdout
    #         log file: The message is printed to a log file
    # USAGE:
    #         [_alertType] "[MESSAGE]" "${LINENO}"
    # NOTES:
    #         - The colors of each alert type are set in this function
    #         - For specified alert types, the funcstac will be printed

    local _color
    local _alertType="${1}"
    local _message="${2}"
    local _line="${3:-}" # Optional line number

    [[ $# -lt 2 ]] && fatal 'Missing required argument to _alert_'

    if [[ -n ${_line} && ${_alertType} =~ ^(fatal|error) && ${FUNCNAME[2]} != "_trapCleanup_" ]]; then
        _message="${_message} ${gray}(line: ${_line}) $(_printFuncStack_)"
    elif [[ -n ${_line} && ${FUNCNAME[2]} != "_trapCleanup_" ]]; then
        _message="${_message} ${gray}(line: ${_line})"
    elif [[ -z ${_line} && ${_alertType} =~ ^(fatal|error) && ${FUNCNAME[2]} != "_trapCleanup_" ]]; then
        _message="${_message} ${gray}$(_printFuncStack_)"
    fi

    if [[ ${_alertType} =~ ^(error|fatal) ]]; then
        _color="${bold}${red}"
    elif [ "${_alertType}" == "info" ]; then
        _color="${gray}"
    elif [ "${_alertType}" == "warning" ]; then
        _color="${red}"
    elif [ "${_alertType}" == "success" ]; then
        _color="${green}"
    elif [ "${_alertType}" == "debug" ]; then
        _color="${purple}"
    elif [ "${_alertType}" == "header" ]; then
        _color="${bold}${white}${underline}"
    elif [ "${_alertType}" == "notice" ]; then
        _color="${bold}"
    elif [ "${_alertType}" == "input" ]; then
        _color="${bold}${underline}"
    else
        _color=""
    fi

    _writeToScreen_() {
        if ! [[ -t 1 || -z ${TERM:-} ]]; then # Don't use colors on non-recognized terminals
            _color=""
            reset=""
        fi

        if [[ ${_alertType} == header ]]; then
            printf "${_color}%s${reset}\n" "${_message}"
        else
            printf "${_color}[%7s] %s${reset}\n" "${_alertType}" "${_message}"
        fi
    }
    _writeToScreen_

    _writeToLog_() {
        [[ ${_alertType} == "input" ]] && return 0
        [[ ${LOGLEVEL} =~ (off|OFF|Off) ]] && return 0
        if [ -z "${LOGFILE:-}" ]; then
            LOGFILE="$(pwd)/$(basename "$0").log"
        fi
        [ ! -d "$(dirname "${LOGFILE}")" ] && mkdir -p "$(dirname "${LOGFILE}")"
        [[ ! -f ${LOGFILE} ]] && touch "${LOGFILE}"

        # Don't use colors in logs
        local _cleanmessage
        _cleanmessage="$(printf "%s" "${_message}" | sed -E 's/(\x1b)?\[(([0-9]{1,2})(;[0-9]{1,3}){0,2})?[mGK]//g')"
        # Print message to log file
        printf "%s [%7s] %s %s\n" "$(date +"%b %d %R:%S")" "${_alertType}" "[$(/bin/hostname)]" "${_cleanmessage}" >>"${LOGFILE}"
    }

    # Write specified log level data to logfile
    case "${LOGLEVEL:-ERROR}" in
        ALL | all | All)
            _writeToLog_
            ;;
        DEBUG | debug | Debug)
            _writeToLog_
            ;;
        INFO | info | Info)
            if [[ ${_alertType} =~ ^(error|fatal|warning|info|notice|success) ]]; then
                _writeToLog_
            fi
            ;;
        NOTICE | notice | Notice)
            if [[ ${_alertType} =~ ^(error|fatal|warning|notice|success) ]]; then
                _writeToLog_
            fi
            ;;
        WARN | warn | Warn)
            if [[ ${_alertType} =~ ^(error|fatal|warning) ]]; then
                _writeToLog_
            fi
            ;;
        ERROR | error | Error)
            if [[ ${_alertType} =~ ^(error|fatal) ]]; then
                _writeToLog_
            fi
            ;;
        FATAL | fatal | Fatal)
            if [[ ${_alertType} =~ ^fatal ]]; then
                _writeToLog_
            fi
            ;;
        OFF | off)
            return 0
            ;;
        *)
            if [[ ${_alertType} =~ ^(error|fatal) ]]; then
                _writeToLog_
            fi
            ;;
    esac

} # /_alert_

error() { _alert_ error "${1}" "${2:-}"; }
warning() { _alert_ warning "${1}" "${2:-}"; }
notice() { _alert_ notice "${1}" "${2:-}"; }
info() { _alert_ info "${1}" "${2:-}"; }
success() { _alert_ success "${1}" "${2:-}"; }
input() { _alert_ input "${1}" "${2:-}"; }
header() { _alert_ header "${1}" "${2:-}"; }
debug() { _alert_ debug "${1}" "${2:-}"; }
fatal() {
    _alert_ fatal "${1}" "${2:-}"
    _safeExit_ "1"
}

_printFuncStack_() {
    # DESC:
    #         Prints the function stack in use. Used for debugging, and error reporting.
    # ARGS:
    #         None
    # OUTS:
    #         stdout: Prints [function]:[file]:[line]
    # NOTE:
    #         Does not print functions from the alert class
    local _i
    declare -a _funcStackResponse=()
    for ((_i = 1; _i < ${#BASH_SOURCE[@]}; _i++)); do
        case "${FUNCNAME[${_i}]}" in
            _alert_ | _trapCleanup_ | fatal | error | warning | notice | info | debug | header | success)
                continue
                ;;
            *)
                _funcStackResponse+=("${FUNCNAME[${_i}]}:$(basename "${BASH_SOURCE[${_i}]}"):${BASH_LINENO[_i - 1]}")
                ;;
        esac

    done
    printf "( "
    printf %s "${_funcStackResponse[0]}"
    printf ' < %s' "${_funcStackResponse[@]:1}"
    printf ' )\n'
}

_safeExit_() {
    # DESC:
    #       Cleanup and exit from a script
    # ARGS:
    #       $1 (optional) - Exit code (defaults to 0)
    # OUTS:
    #       None

    if [[ -d ${SCRIPT_LOCK:-} ]]; then
        if command rm -rf "${SCRIPT_LOCK}"; then
            debug "Removing script lock"
        else
            warning "Script lock could not be removed. Try manually deleting ${yellow}'${SCRIPT_LOCK}'"
        fi
    fi

    if [[ -n ${TMP_DIR:-} && -d ${TMP_DIR:-} ]]; then
        if [[ ${1:-} == 1 && -n "$(ls "${TMP_DIR}")" ]]; then
            command rm -r "${TMP_DIR}"
        else
            command rm -r "${TMP_DIR}"
            debug "Removing temp directory"
        fi
    fi

    trap - INT TERM EXIT
    exit "${1:-0}"
}

_trapCleanup_() {
    # DESC:
    #         Log errors and cleanup from script when an error is trapped.  Called by 'trap'
    # ARGS:
    #         $1:  Line number where error was trapped
    #         $2:  Line number in function
    #         $3:  Command executing at the time of the trap
    #         $4:  Names of all shell functions currently in the execution call stack
    #         $5:  Scriptname
    #         $6:  $BASH_SOURCE
    # USAGE:
    #         trap '_trapCleanup_ ${LINENO} ${BASH_LINENO} "${BASH_COMMAND}" "${FUNCNAME[*]}" "${0}" "${BASH_SOURCE[0]}"' EXIT INT TERM SIGINT SIGQUIT SIGTERM ERR
    # OUTS:
    #         Exits script with error code 1

    local _line=${1:-} # LINENO
    local _linecallfunc=${2:-}
    local _command="${3:-}"
    local _funcstack="${4:-}"
    local _script="${5:-}"
    local _sourced="${6:-}"

    # Replace the cursor in-case 'tput civis' has been used
    tput cnorm

    if declare -f "fatal" &>/dev/null && declare -f "_printFuncStack_" &>/dev/null; then

        _funcstack="'$(printf "%s" "${_funcstack}" | sed -E 's/ / < /g')'"

        if [[ ${_script##*/} == "${_sourced##*/}" ]]; then
            fatal "${7:-} command: '${_command}' (line: ${_line}) [func: $(_printFuncStack_)]"
        else
            fatal "${7:-} command: '${_command}' (func: ${_funcstack} called at line ${_linecallfunc} of '${_script##*/}') (line: ${_line} of '${_sourced##*/}') "
        fi
    else
        printf "%s\n" "Fatal error trapped. Exiting..."
    fi

    if declare -f _safeExit_ &>/dev/null; then
        _safeExit_ 1
    else
        exit 1
    fi
}

_makeTempDir_() {
    # DESC:
    #         Creates a temp directory to house temporary files
    # ARGS:
    #         $1 (Optional) - First characters/word of directory name
    # OUTS:
    #         Sets $TMP_DIR variable to the path of the temp directory
    # USAGE:
    #         _makeTempDir_ "$(basename "$0")"

    [ -d "${TMP_DIR:-}" ] && return 0

    if [ -n "${1:-}" ]; then
        TMP_DIR="${TMPDIR:-/tmp/}${1}.${RANDOM}.${RANDOM}.$$"
    else
        TMP_DIR="${TMPDIR:-/tmp/}$(basename "$0").${RANDOM}.${RANDOM}.${RANDOM}.$$"
    fi
    (umask 077 && mkdir "${TMP_DIR}") || {
        fatal "Could not create temporary directory! Exiting."
    }
    debug "\$TMP_DIR=${TMP_DIR}"
}

_parseOptions_() {
    # DESC:
    #					Iterates through options passed to script and sets variables. Will break -ab into -a -b
    #         when needed and --foo=bar into --foo bar
    # ARGS:
    #					$@ from command line
    # OUTS:
    #					Sets array 'ARGS' containing all arguments passed to script that were not parsed as options
    # USAGE:
    #					_parseOptions_ "$@"

    # Iterate over options
    local _optstring=h
    declare -a _options
    local _c
    local i
    while (($#)); do
        case $1 in
            # If option is of type -ab
            -[!-]?*)
                # Loop over each character starting with the second
                for ((i = 1; i < ${#1}; i++)); do
                    _c=${1:i:1}
                    _options+=("-${_c}") # Add current char to options
                    # If option takes a required argument, and it's not the last char make
                    # the rest of the string its argument
                    if [[ ${_optstring} == *"${_c}:"* && -n ${1:i+1} ]]; then
                        _options+=("${1:i+1}")
                        break
                    fi
                done
                ;;
            # If option is of type --foo=bar
            --?*=*) _options+=("${1%%=*}" "${1#*=}") ;;
            # add --endopts for --
            --) _options+=(--endopts) ;;
            # Otherwise, nothing special
            *) _options+=("$1") ;;
        esac
        shift
    done
    set -- "${_options[@]:-}"
    unset _options

    # Read the options and set stuff
    # shellcheck disable=SC2034
    while [[ ${1:-} == -?* ]]; do
        case $1 in
            # Custom options

            # Common options
            -h | --help)
                _usage_
                _safeExit_
                ;;
            --loglevel)
                shift
                LOGLEVEL=${1}
                ;;
            --logfile)
                shift
                LOGFILE="${1}"
                ;;
            --endopts)
                shift
                break
                ;;
            *)
                if declare -f _safeExit_ &>/dev/null; then
                    fatal "invalid option: $1"
                else
                    printf "%s\n" "ERROR: Invalid option: $1"
                    exit 1
                fi
                ;;
        esac
        shift
    done

    if [[ -z ${*} || ${*} == null ]]; then
        ARGS=()
    else
        ARGS+=("$@") # Store the remaining user input as arguments.
    fi
}

_columns_() {
    # DESC:
    #         Prints a two column output from a key/value pair.
    #         Optionally pass a number of 2 space tabs to indent the output.
    # ARGS:
    #         $1 (required): Key name (Left column text)
    #         $2 (required): Long value (Right column text. Wraps around if too long)
    #         $3 (optional): Number of 2 character tabs to indent the command (default 1)
    # OPTS:
    #         -b    Bold the left column
    #         -u    Underline the left column
    #         -r    Reverse background and foreground colors
    # OUTS:
    #         stdout: Prints the output in columns
    # NOTE:
    #         Long text or ANSI colors in the first column may create display issues
    # USAGE:
    #         _columns_ "Key" "Long value text" [tab level]

    [[ $# -lt 2 ]] && fatal "Missing required argument to ${FUNCNAME[0]}"

    local opt
    local OPTIND=1
    local _style=""
    while getopts ":bBuUrR" opt; do
        case ${opt} in
            b | B) _style="${_style}${bold}" ;;
            u | U) _style="${_style}${underline}" ;;
            r | R) _style="${_style}${reverse}" ;;
            *) fatal "Unrecognized option '${1}' passed to ${FUNCNAME[0]}. Exiting." ;;
        esac
    done
    shift $((OPTIND - 1))

    local _key="${1}"
    local _value="${2}"
    local _tabLevel="${3-}"
    local _tabSize=2
    local _line
    local _rightIndent
    local _leftIndent
    if [[ -z ${3-} ]]; then
        _tabLevel=0
    fi

    _leftIndent="$((_tabLevel * _tabSize))"

    local _leftColumnWidth="$((30 + _leftIndent))"

    if [ "$(tput cols)" -gt 180 ]; then
        _rightIndent=110
    elif [ "$(tput cols)" -gt 160 ]; then
        _rightIndent=90
    elif [ "$(tput cols)" -gt 130 ]; then
        _rightIndent=60
    elif [ "$(tput cols)" -gt 120 ]; then
        _rightIndent=50
    elif [ "$(tput cols)" -gt 110 ]; then
        _rightIndent=40
    elif [ "$(tput cols)" -gt 100 ]; then
        _rightIndent=30
    elif [ "$(tput cols)" -gt 90 ]; then
        _rightIndent=20
    elif [ "$(tput cols)" -gt 80 ]; then
        _rightIndent=10
    else
        _rightIndent=0
    fi

    local _rightWrapLength=$(($(tput cols) - _leftColumnWidth - _leftIndent - _rightIndent))

    local _first_line=0
    while read -r _line; do
        if [[ ${_first_line} -eq 0 ]]; then
            _first_line=1
        else
            _key=" "
        fi
        printf "%-${_leftIndent}s${_style}%-${_leftColumnWidth}b${reset} %b\n" "" "${_key}${reset}" "${_line}"
    done <<<"$(fold -w${_rightWrapLength} -s <<<"${_value}")"
}

_usage_() {
    cat <<USAGE_TEXT
  ${bold}$(basename "$0") [OPTION]... [FILE]...${reset}
  Data Migration Service script to provide sql instructions to prepare your source/target database for migration.
  Run the script and preparation parameters will be asked on the march.
  Please ensure that the Bash shell level used is 4.4 or higher.

  ${bold}${underline}Options:${reset}
$(_columns_ -b -- '-h, --help' "Display this help and exit" 2)
$(_columns_ -b -- "--loglevel [LEVEL]" "One of: FATAL, ERROR (default), WARN, INFO, NOTICE, DEBUG, ALL, OFF" 2)
$(_columns_ -b -- "--logfile [FILE]" "Full PATH to logfile.  (Default is '\${HOME}/logs/$(basename "$0").log')" 2)
  ${bold}${underline}Example Usage:${reset}
    ${gray}# Run the script using default values.${reset}
    $(basename "$0")
    ${gray}# Run the script and specify log level and log file.${reset}
    $(basename "$0") --logfile "/path/to/file.log" --loglevel 'WARN'
USAGE_TEXT
}

# ################################## INITIALIZE AND RUN THE SCRIPT
#                                    (Comment or uncomment the lines below to customize script behavior)

trap '_trapCleanup_ ${LINENO} ${BASH_LINENO} "${BASH_COMMAND}" "${FUNCNAME[*]}" "${0}" "${BASH_SOURCE[0]}"' EXIT INT TERM SIGINT SIGQUIT SIGTERM

# Trap errors in subshells and functions
set -o errtrace

# Exit on error. Append '||true' if you expect an error
set -o errexit

# Use last non-zero exit code in a pipeline
set -o pipefail

# Set IFS to preferred implementation
IFS=$' \n\t'

# Run in debug mode
# set -o xtrace

# Initialize color constants
_setColors_

# Disallow expansion of unset variables
set -o nounset

# Parse arguments passed to script
_parseOptions_ "$@"

# Run the main logic script
_mainScript_

# Exit cleanly
_safeExit_
