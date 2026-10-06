#!/bin/ksh

################################################################################
# Script Name: validate_po_duplicates.ksh
# Description: Validate duplicate PO records using composite key (PO+STORE+DATE+AMOUNT)
#              Before loading into MIK_OCF_SUMMARY_TBL and MIK_OCF_DETAIL_TBL
# Author: TCS
# Date: May 2026
# Version: 1.0
################################################################################

# Enable error handling
set -e

SOURCE_FILE=$1

if [ -z "$SOURCE_FILE" ] || [ ! -f "$SOURCE_FILE" ]; then
    echo "ERROR: Source file not provided or does not exist: $SOURCE_FILE"
    exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
TEMP_DIR="/tmp"
LOG_FILE="${TEMP_DIR}/validation_${TIMESTAMP}.log"

# File declarations
SOURCE_SUMMARY_KEYS="${TEMP_DIR}/source_summary_keys_${TIMESTAMP}.txt"
EXISTING_SUMMARY_KEYS="${TEMP_DIR}/existing_summary_keys_${TIMESTAMP}.txt"
DUPLICATE_SUMMARY_KEYS="${TEMP_DIR}/duplicate_summary_keys_${TIMESTAMP}.txt"
DUPLICATE_PO_LIST="${TEMP_DIR}/duplicate_po_list_${TIMESTAMP}.txt"
FILTERED_FILE="${TEMP_DIR}/filtered_file_${TIMESTAMP}.txt"
REJECTION_REPORT="${TEMP_DIR}/rejection_report_${TIMESTAMP}.txt"
VALIDATION_STATS="${TEMP_DIR}/validation_stats_${TIMESTAMP}.txt"

{
    echo "════════════════════════════════════════════════════════════════"
    echo "STARTING PO DUPLICATE VALIDATION - COMPOSITE KEY CHECK"
    echo "════════════════════════════════════════════════════════════════"
    echo "Timestamp: $TIMESTAMP"
    echo "Source File: $SOURCE_FILE"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # STEP 1: Extract SUMMARY composite keys from source file
    # ─────────────────────────────────────────────────────────────────────
    echo "STEP 1: Extracting source SUMMARY composite keys..."
    
    grep "^S|" "$SOURCE_FILE" | \
      awk -F'|' '{
        # Build composite key: PO|STORE|DATE|AMOUNT
        po = $5
        store = $8
        date = $11
        amount = $21
        key = po "|" store "|" date "|" amount
        print key
      }' | sort -u > "$SOURCE_SUMMARY_KEYS"

    SOURCE_SUMMARY_COUNT=$(wc -l < "$SOURCE_SUMMARY_KEYS")
    echo "  ✓ Extracted $SOURCE_SUMMARY_COUNT unique SUMMARY composite keys"

    # ─────────────────────────────────────────────────────────────────────
    # STEP 2: Extract existing composite keys from database
    # ─────────────────────────────────────────────────────────────────────
    echo "STEP 2: Extracting existing SUMMARY composite keys from database..."
    
    sqlplus -s $UP <<SQLQUERY > "$EXISTING_SUMMARY_KEYS" 2>/dev/null
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT DISTINCT 
  REPLACE(PO_NUMBER, 'MCF', '') || '|' ||
  STORE_NUMBER || '|' ||
  TO_CHAR(DATE_OF_SALE, 'DD-Mon-YYYY') || '|' ||
  AMOUNT_FROM_PROCESSOR
FROM MIK_OCF_SUMMARY_TBL
WHERE PO_NUMBER IS NOT NULL
ORDER BY 1;
EXIT;
SQLQUERY

    EXISTING_SUMMARY_COUNT=$(wc -l < "$EXISTING_SUMMARY_KEYS")
    echo "  ✓ Found $EXISTING_SUMMARY_COUNT existing SUMMARY composite keys in database"

    # ─────────────────────────────────────────────────────────────────────
    # STEP 3: Find duplicate composite keys
    # ─────────────────────────────────────────────────────────────────────
    echo "STEP 3: Comparing keys and identifying duplicates..."
    
    comm -12 <(sort "$SOURCE_SUMMARY_KEYS") \
             <(sort "$EXISTING_SUMMARY_KEYS") > "$DUPLICATE_SUMMARY_KEYS" || true

    DUPLICATE_SUMMARY_COUNT=$(wc -l < "$DUPLICATE_SUMMARY_KEYS")
    echo "  ✓ Found $DUPLICATE_SUMMARY_COUNT duplicate SUMMARY composite keys"

    # ─────────────────────────────────────────────────────────────────────
    # STEP 4: Extract PO numbers from duplicate keys
    # ─────────────────────────────────────────────────────────────────────
    echo "STEP 4: Extracting PO numbers from duplicate keys..."
    
    cut -d'|' -f1 "$DUPLICATE_SUMMARY_KEYS" | sort -u > "$DUPLICATE_PO_LIST" || true

    DUPLICATE_PO_COUNT=$(wc -l < "$DUPLICATE_PO_LIST")
    echo "  ✓ Identified $DUPLICATE_PO_COUNT unique PO numbers as duplicates"

    # ─────────────────────────────────────────────────────────────────────
    # STEP 5: Create filtered source file
    # ─────────────────────────────────────────────────────────────────────
    echo "STEP 5: Filtering source file..."
    
    awk -v dup_keys_file="$DUPLICATE_SUMMARY_KEYS" \
        -v dup_po_file="$DUPLICATE_PO_LIST" \
        -v reject_file="$REJECTION_REPORT" \
        'BEGIN {
          # Load duplicate composite keys
          while ((getline line < dup_keys_file) > 0) {
            dup_keys[line] = 1
          }
          close(dup_keys_file)
          
          # Load duplicate PO numbers
          while ((getline line < dup_po_file) > 0) {
            dup_pos[line] = 1
          }
          close(dup_po_file)
          
          excluded_summary = 0
          excluded_detail = 0
          included_total = 0
        }
        {
          if ($0 ~ /^H/) {
            # Header - always include
            print $0
            included_total++
          }
          else if ($0 ~ /^S/) {
            # Summary record
            split($0, arr, "|")
            po = arr[5]
            store = arr[8]
            date = arr[11]
            amount = arr[21]
            key = po "|" store "|" date "|" amount
            
            if (key in dup_keys) {
              print key " |S|DUPLICATE_COMPOSITE_KEY_SUMMARY" >> reject_file
              excluded_summary++
            }
            else {
              print $0
              included_total++
            }
          }
          else if ($0 ~ /^D/) {
            # Detail record
            split($0, arr, "|")
            po = arr[3]
            
            if (po in dup_pos) {
              print po "  |D|DUPLICATE_PO_FROM_SUMMARY" >> reject_file
              excluded_detail++
            }
            else {
              print $0
              included_total++
            }
          }
          else {
            # Other records - include as is
            print $0
            included_total++
          }
        }
        END {
          print "EXCLUDED_SUMMARY:" excluded_summary > "/tmp/validation_counts_${TIMESTAMP}.txt"
          print "EXCLUDED_DETAIL:" excluded_detail >> "/tmp/validation_counts_${TIMESTAMP}.txt"
          print "INCLUDED_TOTAL:" included_total >> "/tmp/validation_counts_${TIMESTAMP}.txt"
        }' "$SOURCE_FILE" > "$FILTERED_FILE"

    # Read counts from temporary file
    eval $(sed 's/ //g' "/tmp/validation_counts_${TIMESTAMP}.txt" | sed 's/:/ = /g')
    rm -f "/tmp/validation_counts_${TIMESTAMP}.txt"

    echo "  ✓ Records excluded from SUMMARY: $EXCLUDED_SUMMARY"
    echo "  ✓ Records excluded from DETAIL:  $EXCLUDED_DETAIL"
    echo "  ✓ Records included in filtered file: $INCLUDED_TOTAL"

    # ─────────────────────────────────────────────────────────────────────
    # STEP 6: Create validation summary statistics
    # ─────────────────────────────────────────────────────────────────────
    echo "STEP 6: Creating validation summary report..."
    
    cat > "$VALIDATION_STATS" <<EOF
════════════════════════════════════════════════════════════════
VALIDATION SUMMARY - COMPOSITE KEY DUPLICATE CHECK
════════════════════════════════════════════════════════════════
Execution Timestamp: $TIMESTAMP
Source File: $SOURCE_FILE

EXTRACTED STATISTICS:
  Source SUMMARY Composite Keys:   $SOURCE_SUMMARY_COUNT
  Existing DB Composite Keys:      $EXISTING_SUMMARY_COUNT
  Duplicate Keys Found:            $DUPLICATE_SUMMARY_COUNT
  Duplicate PO Numbers Identified: $DUPLICATE_PO_COUNT

FILTERING RESULTS:
  Summary Records Excluded:        $EXCLUDED_SUMMARY
  Detail Records Excluded:         $EXCLUDED_DETAIL
  Records Ready for Load:          $INCLUDED_TOTAL

OUTPUT FILES CREATED:
  Filtered Source File:    $FILTERED_FILE
  Rejection Report:        $REJECTION_REPORT
  Validation Stats:        $VALIDATION_STATS
  Keys (Source):           $SOURCE_SUMMARY_KEYS
  Keys (Existing DB):      $EXISTING_SUMMARY_KEYS
  Keys (Duplicates):       $DUPLICATE_SUMMARY_KEYS
  PO List (Duplicates):    $DUPLICATE_PO_LIST

════════════════════════════════════════════════════════════════
EOF

    cat "$VALIDATION_STATS"
    
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "VALIDATION COMPLETE"
    echo "════════════════════════════════════════════════════════════════"

} | tee "$LOG_FILE"

# Export filtered file path for use in main script
export FILTERED_SOURCE_FILE="$FILTERED_FILE"
export VALIDATION_LOG_FILE="$LOG_FILE"
export REJECTION_REPORT_FILE="$REJECTION_REPORT"
export VALIDATION_STATS_FILE="$VALIDATION_STATS"

# Return filtered file path via echo for sourcing in parent script
echo "$FILTERED_FILE"

exit 0
