#!/usr/bin/ksh

################################################################################
# Script Name: mik_ocf_sales_import.ksh
# Description: Load OCF Sales data from file into staging tables and invoke sales import
# Author: TCS
# Date: May 2026
# Version: 1.0
################################################################################
# set -x

# Load environment variables (modify path as per your environment)
. /app/oretail/rms/12.0/mod/bin/resa_daily.env

# Set up variables
export PROGRAM=$(basename $0 .ksh)
export DATE=`date +%Y%m%d`
export LOGFILE=$MMHOME/log/$PROGRAM.`date +%b_%d.%H%M%S`.log
export ERRORFILE=$MMHOME/error/err.${PROGRAM}.`date +%b_%d`
TIMESTAMP=$(date +"%Y%m%d%H%M")
export PROCESS_IN_DIR=/app/oretail/rms/12.0/mod/FINANCE/inbound
export PROCESS_OUT_DIR=/app/oretail/rms/12.0/mod/FINANCE/outbound
ScriptDir="/app/oretail/rms/12.0/mod/FINANCE/scripts"
BackupDir=$PROCESS_OUT_DIR/backup
control_file=$ScriptDir/ocf_sales_load.ctl
control_file_det=$ScriptDir/ocf_sales_det_load.ctl
export LDRLOGFILE=$PROCESS_OUT_DIR/OCF_SALES_DATA_LOAD_$TIMESTAMP.log
export ARCHIVE_DIR=/app/oretail/rms/12.0/mod/FINANCE/inbound/backup

################################################################################
# Function: log_msg
# Description: Log message to log file
################################################################################
log_msg()
{
   LOG_START_MSG=`date +"%a %b  %e %H:%M:%S"`" Program: $PROGRAM: "
   LOG_MSG="${LOG_START_MSG}${LOG_TXT}"
   echo $LOG_MSG >> ${LOGFILE}
}

log_start_msg()
{
   LOG_TXT="Started by "$(whoami)
   log_msg
}

log_end_msg()
{
   LOG_TXT="Terminated OK...."
   log_msg
   exit 0
}

error_msg()
{
   ERROR_START_MSG=`date +"%a %b  %e %H:%M:%S"`" Program: $PROGRAM: "
   ERROR_MSG="${ERROR_START_MSG}${ERROR_TXT}"
   echo $ERROR_MSG >> ${ERRORFILE}
}

################################################################################
# Main Processing
################################################################################

log_start_msg

echo "`date +%Y-%m-%d-%H:%M:%S` $PROGRAM Script Started"
LOG_TXT="$PROGRAM Script Started"
log_msg

# Clean up old files
rm -f $PROCESS_OUT_DIR/OCF_SALES_DATA_LOAD*.log
rm -f $PROCESS_OUT_DIR/OCF_SALES_*.dat
rm -f $PROCESS_OUT_DIR/OCF_SALES_*.bad
echo "Old files removed."

# Check if input file exists
if ! ls $PROCESS_IN_DIR/EODExportFile*.txt 1> /dev/null 2>&1; then
    echo "Error: No input file found in $PROCESS_IN_DIR."
    ERROR_TXT="Error: No input file found in $PROCESS_IN_DIR"
    error_msg
    exit 1
fi

# Clear existing data from staging tables
#echo "Clearing existing data from staging tables..."
#$ORACLE_HOME/bin/sqlplus -s $UP <<EOF
#SET SERVEROUTPUT ON;
#DELETE FROM MIK_OCF_SUMMARY_TBL;
#DELETE FROM MIK_OCF_DETAIL_TBL;
#COMMIT;
#EXIT;
#EOF

if [ $? -ne 0 ]; then
    echo "Error: Failed to clear staging tables"
    ERROR_TXT="Error: Failed to clear staging tables"
    error_msg
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────
# Pre-load validation: Composite key duplicate check
# ─────────────────────────────────────────────────────────────────────
echo "Performing pre-load validation..."
LOG_TXT="Performing pre-load validation for duplicate PO records"
log_msg

for FILE in $PROCESS_IN_DIR/EODExportFile*.txt; do
    FILENAME=$(basename "$FILE")
    
    echo "Running validation script for: $FILENAME"
    
    # Source the validation script and capture filtered file path
    FILTERED_FILE=$($ScriptDir/validate_po_duplicates.ksh "$FILE" 2>&1 | tail -n1)
    VALIDATION_EXIT=$?
    
    if [ $VALIDATION_EXIT -ne 0 ] || [ -z "$FILTERED_FILE" ]; then
        echo "Error: Validation script failed"
        ERROR_TXT="Error: Validation script failed for $FILENAME"
        error_msg
        exit 1
    fi
    
    if [ ! -f "$FILTERED_FILE" ]; then
        echo "Error: Filtered file not created: $FILTERED_FILE"
        ERROR_TXT="Error: Filtered file not created: $FILTERED_FILE"
        error_msg
        exit 1
    fi
    
    echo "Validation passed. Using filtered file: $FILTERED_FILE"
    LOG_TXT="Validation passed for $FILENAME. Filtered file ready for load"
    log_msg
done

# ─────────────────────────────────────────────────────────────────────
# Process input file with SQL*Loader (using filtered files)
# ─────────────────────────────────────────────────────────────────────
for FILE in $PROCESS_IN_DIR/EODExportFile*.txt; do
    FILENAME=$(basename "$FILE")
    
    # Get filtered file path
    FILTERED_FILE=$($ScriptDir/validate_po_duplicates.ksh "$FILE" 2>&1 | tail -n1)
    
    NEW_FILENAME="${FILENAME%.txt}_$TIMESTAMP.dat"

    # Copy the filtered file
    cp "$FILTERED_FILE" "$PROCESS_OUT_DIR/$NEW_FILENAME"
    
    if [ $? -ne 0 ]; then
        echo "Error: Unable to copy $FILTERED_FILE to $NEW_FILENAME"
        ERROR_TXT="Error: Unable to copy filtered file to $NEW_FILENAME"
        error_msg
        exit 1
    fi

    echo "Loading filtered data using SQL*Loader..."
    LOG_TXT="Loading filtered data using SQL*Loader for $FILENAME"
    log_msg
    
    # Run SQL*Loader
    sqlldr $UP control=$control_file data="$PROCESS_OUT_DIR/$NEW_FILENAME" log=$LDRLOGFILE bad=$PROCESS_OUT_DIR/${NEW_FILENAME}.bad errors=10000
    status=$?
    sqlldr $UP control=$control_file_det data="$PROCESS_OUT_DIR/$NEW_FILENAME" log=$LDRLOGFILE bad=$PROCESS_OUT_DIR/${NEW_FILENAME}.bad errors=10000
    status_d=$?
	
    if [ $status -eq 3 ||  $status_d -eq 3 ]; then
        echo "File not found in $PROCESS_OUT_DIR."
        ERROR_TXT="File not found in $PROCESS_OUT_DIR"
        error_msg
        exit 1
    elif [ $status -eq 2 ||  $status_d -eq 3 ]; then
        if [ -f $PROCESS_OUT_DIR/${NEW_FILENAME}.bad ]; then
            mv $PROCESS_OUT_DIR/${NEW_FILENAME}.bad $BackupDir/${NEW_FILENAME}_$TIMESTAMP.bad
            echo "SQL Loader completed with WARNING. Refer to the bad file ${NEW_FILENAME}_$TIMESTAMP.bad in the $BackupDir folder."
            LOG_TXT="SQL Loader completed with WARNING"
            log_msg
        else
            echo "All valid rows loaded successfully - $NEW_FILENAME"
            LOG_TXT="All valid rows loaded successfully - $NEW_FILENAME"
            log_msg
        fi
    elif [ $status -eq 1 ||  $status_d -eq 3 ]; then
        echo "Error while loading $NEW_FILENAME" >> $LDRLOGFILE
        echo "Error while loading $NEW_FILENAME"
        ERROR_TXT="Error while loading $NEW_FILENAME"
        error_msg
        mv $PROCESS_OUT_DIR/$NEW_FILENAME $BackupDir/$NEW_FILENAME
        exit 2
    else
        echo "SQL Loader completed successfully"
        LOG_TXT="SQL Loader completed successfully"
        log_msg
    fi

	# Update filename staging tables
	echo "Update Filename on staging tables..."
	RESULT=`sqlplus -s $UP << SQLSTRING
	SET SERVEROUTPUT ON SIZE UNLIMITED;
	SET FEEDBACK OFF;
	VARIABLE t_return_code NUMBER;
	WHENEVER SQLERROR EXIT 2
	DECLARE
		-- Safely bring the Unix variable into PL/SQL with single quotes
		t_filename VARCHAR2(255) := '$FILENAME';	
	begin 
	    update MIK_OCF_SUMMARY_TBL set filename = t_filename where filename is null ;
		
		update MIK_OCF_DETAIL_TBL set filename = t_filename where filename is null ;
		 		  
		commit;  
		:t_return_code := 0;
	exception 
		when others then
			:t_return_code := -1;
	END;
	/
	EXIT :t_return_code;
	SQLSTRING`

	status=$?

	if [ $status -ne 0 ]; then
		echo "Error while updating filename"
		echo "OUTPUT: $RESULT"
		ERROR_TXT="Error while updating filename. OUTPUT: $RESULT"
		error_msg
		exit 1
	else
		echo "SUCCESS: Filename Updated successfully"
		LOG_TXT="SUCCESS: Filename Updated successfully"
		log_msg
		echo "$RESULT"
	fi	
    
    # Move processed file to backup
    #mv $PROCESS_OUT_DIR/$NEW_FILENAME $BackupDir/$NEW_FILENAME
    #
    #if [ $? -ne 0 ]; then
    #    echo "Error: Unable to move file to backup directory"
    #    LOG_TXT="Error: Unable to move file to backup directory"
    #    log_msg
    #    exit 1
    #fi
    
    # Move original input file to archive directory after successful processing
    mkdir -p "$ARCHIVE_DIR"
    mv "$FILE" "$ARCHIVE_DIR/"
    
    if [ $? -eq 0 ]; then
        echo "File archived successfully: $FILENAME"
        LOG_TXT="File archived successfully: $FILENAME to $ARCHIVE_DIR"
        log_msg
    else
        echo "Warning: Unable to archive file $FILENAME"
        LOG_TXT="Warning: Unable to archive file $FILENAME"
        log_msg
    fi
done

# Gather Stats on staging tables
echo "Gather Stats on staging tables..."
RESULT=`sqlplus -s $UP << SQLSTRING
SET SERVEROUTPUT ON SIZE UNLIMITED;
SET FEEDBACK OFF;
VARIABLE t_return_code NUMBER;

WHENEVER SQLERROR EXIT 2
begin 
  	DBMS_STATS.GATHER_TABLE_STATS (
  	  ownname => 'MIK',
      tabname => 'MIK_OCF_SUMMARY_TBL',
      estimate_percent => 10);

  	DBMS_STATS.GATHER_TABLE_STATS (
  	  ownname => 'MIK',
      tabname => 'MIK_OCF_DETAIL_TBL',
      estimate_percent => 10);	  
	  
	:t_return_code := 0;

exception 
	when others then
		:t_return_code := -1;
END;
/
EXIT :t_return_code;
SQLSTRING`

status=$?

if [ $status -ne 0 ]; then
    echo "Error while Gathering Stats"
    echo "OUTPUT: $RESULT"
    ERROR_TXT="Error while Gathering Stats. OUTPUT: $RESULT"
    error_msg
    exit 1
else
    echo "SUCCESS: Gathered Stats successfully"
    LOG_TXT="SUCCESS: Gathered Stats successfully"
    log_msg
    echo "$RESULT"
fi

# Get record counts from staging tables
echo "Getting record counts from staging tables..."
RESULT=$($ORACLE_HOME/bin/sqlplus -s $UP <<EOF
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT COUNT(*) FROM MIK_OCF_SUMMARY_TBL WHERE INSERTTIME >= trunc(sysdate);
EXIT;
EOF
)

SUMMARY_CNT=$(echo $RESULT | xargs)
echo "Summary records loaded: $SUMMARY_CNT"

RESULT=$($ORACLE_HOME/bin/sqlplus -s $UP <<EOF
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT COUNT(*) FROM MIK_OCF_DETAIL_TBL WHERE INSERTTIME >= trunc(sysdate);
EXIT;
EOF
)

DETAIL_CNT=$(echo $RESULT | xargs)
echo "Detail records loaded: $DETAIL_CNT"

if [ "$SUMMARY_CNT" -eq 0 ] || [ "$DETAIL_CNT" -eq 0 ]; then
    echo "Error: No data loaded into staging tables"
    ERROR_TXT="Error: No data loaded into staging tables. Summary: $SUMMARY_CNT, Detail: $DETAIL_CNT"
    error_msg
    exit 1
fi

LOG_TXT="Data loaded successfully. Summary: $SUMMARY_CNT, Detail: $DETAIL_CNT"
log_msg

echo "`date +%Y-%m-%d-%H:%M:%S` $PROGRAM Script Completed"
LOG_TXT="$PROGRAM Script Completed Successfully"
log_msg

log_end_msg


