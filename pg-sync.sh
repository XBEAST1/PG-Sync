#!/bin/bash

# PG-Sync: Developer Focused PostgreSQL Backup & Restore Tool
# Author: XBEAST1

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[1;35m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_BASE_DIR="$SCRIPT_DIR/pg-sync-db-backup"
LOCK_FILE="/tmp/pg-sync.lock"

# Acquire lock
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo -e "${RED}Another instance of PG-Sync is running.${NC}"
    exit 1
fi

MIGRATION_TABLES=(
    "alembic_version"
    "flyway_schema_history"
    "schema_migrations"
    "_prisma_migrations"
    "knex_migrations"
    "knex_migrations_lock"
)

cleanup_partial_backup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ -n "$CURRENT_BACKUP_SET" ] && [ -d "$CURRENT_BACKUP_SET" ]; then
        echo -e "${RED}FAILURE DETECTED: Cleaning up incomplete backup set...${NC}"
        rm -rf "$CURRENT_BACKUP_SET"
        echo -e "${YELLOW}Removed: $CURRENT_BACKUP_SET${NC}"
    fi
    # Release lock
    flock -u 9
}

ensure_gitignore() {
    local gitignore_path="$SCRIPT_DIR/.gitignore"
    local script_name="pg-sync.sh"
    local folder_name="pg-sync-db-backup"
    
    [ -f "$gitignore_path" ] && grep -qxF "$folder_name" "$gitignore_path" >/dev/null 2>&1 && return

    echo -e "${CYAN}Adding PG-Sync entries to .gitignore...${NC}\n"
    
    [ -s "$gitignore_path" ] && echo "" >> "$gitignore_path"
    
    echo "" >> "$gitignore_path"
    echo "# PG-Sync Backup Data" >> "$gitignore_path"
    echo "$script_name" >> "$gitignore_path"
    echo "$folder_name" >> "$gitignore_path"
}

get_db_connection() {
    echo -e "${BLUE}Enter the database connection URL:${NC}"
    echo -e "${CYAN}Format: postgresql://username:password@host:port/database_name or postgres://...${NC}"
    echo ""
    read -r DB_URL
    
    if [[ ! "$DB_URL" =~ ^postgres(ql)?:// ]]; then
        echo -e "${RED}✗ Invalid database URL format${NC}"
        exit 1
    fi
    
    local DB_USER=$(echo "$DB_URL" | sed -n 's|^.*://\([^:]*\):.*|\1|p')
    local DB_HOST=$(echo "$DB_URL" | sed -n 's|.*@\([^:]*\):.*|\1|p')
    local DB_PORT=$(echo "$DB_URL" | sed -n 's|.*:\([0-9]*\)/.*|\1|p')
    local DB_NAME=$(echo "$DB_URL" | sed -n 's|.*/\([^/?]*\).*|\1|p')
    
    echo -e "${GREEN}✓ Connection details parsed${NC}"
    echo -e "  Host: ${DB_HOST}"
    echo -e "  Port: ${DB_PORT}"
    echo -e "  Database: ${DB_NAME}"
    echo -e "  User: ${DB_USER}"
    echo ""
}

test_db_connection() {
    echo -e "${YELLOW}Testing connection...${NC}"
    
    if psql "$DB_URL" -c "SELECT 1" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Connection successful${NC}"
        echo ""
        return 0
    else
        echo -e "${RED}✗ Connection failed${NC}"
        echo -e "${YELLOW}Please check your credentials and network access${NC}"
        exit 1
    fi
}

backup_database() {
    TIMESTAMP=$(date +"%d-%m-%Y_%I-%M%p")
    CURRENT_BACKUP_SET="$BACKUP_BASE_DIR/backup_$TIMESTAMP"
    
    # Register cleanup trap
    trap cleanup_partial_backup EXIT INT TERM
    
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}        PG-SYNC: STARTING BACKUP       ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""
    
    mkdir -p "$CURRENT_BACKUP_SET"
    get_db_connection
    test_db_connection
    
    COMMON_FLAGS="--no-owner --no-privileges --no-comments"
    CLEAN_FLAGS="--clean --if-exists"
    EXCLUDE_TABLES=""
    for table in "${MIGRATION_TABLES[@]}"; do EXCLUDE_TABLES="$EXCLUDE_TABLES -T $table"; done
    
    echo -e "${CYAN}[1/3] Dumping Schema...${NC}"
    if ! pg_dump "$DB_URL" $CLEAN_FLAGS $COMMON_FLAGS -v --schema-only -f "$CURRENT_BACKUP_SET/schema.sql" 2>&1; then
        echo -e "${RED}✗ Schema backup failed${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}[2/3] Dumping Data (excluding migrations)...${NC}"
    if ! pg_dump "$DB_URL" $COMMON_FLAGS -v --data-only $EXCLUDE_TABLES -f "$CURRENT_BACKUP_SET/data.sql" 2>&1; then
        echo -e "${RED}✗ Data backup failed${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}[3/3] Dumping Full Backup...${NC}"
    if ! pg_dump "$DB_URL" $CLEAN_FLAGS $COMMON_FLAGS -v -f "$CURRENT_BACKUP_SET/full_data.sql" 2>&1; then
        echo -e "${RED}✗ Full backup failed${NC}"
        exit 1
    fi

    echo -e "${CYAN}[Safety] Verifying integrity...${NC}"
    if [ ! -s "$CURRENT_BACKUP_SET/full_data.sql" ]; then
        echo -e "${RED}✗ Backup integrity check failed: File is empty${NC}"
        exit 1
    fi

    # Generate Checksums
    echo -e "${CYAN}[Safety] Generating SHA256 Checksums...${NC}"
    (cd "$CURRENT_BACKUP_SET" && sha256sum *.sql > checksums.sha256)
    
    # Disable trap on success
    trap - EXIT INT TERM
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}      PG-SYNC: BACKUP SUCCESSFUL       ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}Folder: backup_$TIMESTAMP${NC}"
    echo ""
}

check_if_database_empty() {
    local CHECK_QUERY="SELECT 1 FROM pg_tables WHERE schemaname = 'public' LIMIT 1;"
    local EXISTS=$(psql "$DB_URL" -t -c "$CHECK_QUERY" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$EXISTS" ]]
}

confirm_yes_no() {
    local prompt="$1"
    local response
    while true; do
        read -p "$prompt (yes/no): " response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]) return 1 ;;
            *) echo -e "${RED}Please enter 'yes' or 'no'.${NC}" ;;
        esac
    done
}

check_column_existence() {
    local restore_file="$1"
    echo -e "${YELLOW}Checking column compatibility...${NC}"
    
    MISSING_COLUMNS=""
    local missing_found=false
    # Extract COPY commands and check if columns exist in target DB
    while read -r line; do
        local table_full=$(echo "$line" | awk '{print $2}')
        local table=$(echo "$table_full" | cut -d'.' -f2 | tr -d '"')
        local cols_str=$(echo "$line" | cut -d'(' -f2 | cut -d')' -f1)
        
        IFS=',' read -ra cols_array <<< "$cols_str"
        for col in "${cols_array[@]}"; do
            local col_clean=$(echo "$col" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"')
            local exists=$(psql "$DB_URL" -t -c "SELECT 1 FROM information_schema.columns WHERE table_name='$table' AND column_name='$col_clean';" 2>/dev/null | tr -d '[:space:]')
            if [ -z "$exists" ]; then
                echo -e "${RED}⚠ Column '$col_clean' not found in table '$table'${NC}"
                MISSING_COLUMNS+="${table_full}.${col_clean} "
                missing_found=true
            fi
        done
    done < <(grep "^COPY " "$restore_file")

    if [ "$missing_found" = true ]; then
        echo ""
        if ! confirm_yes_no "Some columns are missing from the target database. Proceed by ignoring them?"; then
            echo -e "${YELLOW}Restore cancelled${NC}"
            exit 0
        fi
        return 1 # Indicate filtering is needed
    else
        echo -e "${GREEN}✓ All backup columns exist in target database${NC}"
        return 0
    fi
}

restore_database() {
    if [ ! -d "$BACKUP_BASE_DIR" ] || [ -z "$(ls -A "$BACKUP_BASE_DIR" 2>/dev/null)" ]; then
        echo -e "${RED}✗ No backups found in $BACKUP_BASE_DIR${NC}"
        exit 1
    fi

    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}        PG-SYNC: SELECT BACKUP         ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""

    # List backup directories sorted by name (date) descending
    mapfile -t BACKUP_SETS < <(ls -d "$BACKUP_BASE_DIR"/backup_* 2>/dev/null | sort -r)
    
    if [ ${#BACKUP_SETS[@]} -eq 0 ]; then
        echo -e "${RED}✗ No backup sets found.${NC}"
        exit 1
    fi

    for i in "${!BACKUP_SETS[@]}"; do
        echo "$((i+1))) $(basename "${BACKUP_SETS[$i]}")"
    done
    echo ""
    while true; do
        read -p "Select a backup set (1-${#BACKUP_SETS[@]}): " set_choice
        if [[ "$set_choice" =~ ^[0-9]+$ ]] && [ "$set_choice" -ge 1 ] && [ "$set_choice" -le ${#BACKUP_SETS[@]} ]; then
            break
        fi
        echo -e "${RED}✗ Invalid selection.${NC}"
    done

    SELECTED_SET="${BACKUP_SETS[$((set_choice-1))]}"
    echo -e "${GREEN}✓ Selected: $(basename "$SELECTED_SET")${NC}"
    echo ""

    while true; do
        echo -e "${CYAN}Select restoration type:${NC}"
        echo "1) Schema only"
        echo "2) Data only"
        echo "3) Full database"
        echo ""
        read -p "Choice (1-3): " type_choice

        case $type_choice in
            1) RESTORE_FILE="$SELECTED_SET/schema.sql"; RESTORE_TYPE="Schema"; break ;;
            2) RESTORE_FILE="$SELECTED_SET/data.sql"; RESTORE_TYPE="Data"; break ;;
            3) RESTORE_FILE="$SELECTED_SET/full_data.sql"; RESTORE_TYPE="Full Database"; break ;;
            *) echo -e "${RED}✗ Invalid choice${NC}" ;;
        esac
    done

    if [ ! -f "$RESTORE_FILE" ]; then
        echo -e "${RED}✗ File not found: $(basename "$RESTORE_FILE")${NC}"
        exit 1
    fi

    echo -e "${CYAN}[Safety] Verifying checksums...${NC}"
    if [ -f "$SELECTED_SET/checksums.sha256" ]; then
        if (cd "$SELECTED_SET" && sha256sum -c checksums.sha256 --status); then
             echo -e "${GREEN}✓ Checksums verified${NC}"
        else
             echo -e "${RED}⚠ CHECKSUM MISMATCH DETECTED!${NC}"
             echo -e "${YELLOW}The backup files may be corrupted or modified.${NC}"
             if ! confirm_yes_no "Do you want to proceed despite the warning?"; then
                 echo -e "${YELLOW}Restore cancelled${NC}"
                 exit 1
             fi
        fi
    else
        echo -e "${YELLOW}⚠ No checksums found (older backup). Skipping verification.${NC}"
    fi

    get_db_connection
    test_db_connection

    local NEEDS_FILTER=0

    if [ "$type_choice" -eq 2 ] || [ "$type_choice" -eq 3 ]; then
        if ! check_column_existence "$RESTORE_FILE"; then
            NEEDS_FILTER=1
        fi
    fi

    echo -e "${CYAN}Restoring $RESTORE_TYPE...${NC}"
    echo ""

    local TRUNCATE_SQL=""
    if [ "$type_choice" -eq 2 ] || [ "$NEEDS_FILTER" -eq 1 ]; then
    
        if [ "$NEEDS_FILTER" -eq 0 ]; then
            if ! confirm_yes_no "Are you sure you want to proceed with the restore?"; then
                echo -e "${YELLOW}Restore cancelled${NC}"
                exit 0
            fi
        fi
        
        if [ "$type_choice" -eq 2 ]; then
            if check_if_database_empty; then 
                echo -e "${GREEN}✓ Database is empty${NC}"
            else
                echo -e "${YELLOW}⚠ Database contains data${NC}"
                if confirm_yes_no "Wipe existing data before restoring?"; then
                    echo -e "${YELLOW}Preparing truncate commands...${NC}"
                    TRUNCATE_SQL=$(psql "$DB_URL" -t -c "SELECT 'TRUNCATE TABLE ' || quote_ident(schemaname) || '.' || quote_ident(tablename) || ' CASCADE;' FROM pg_tables WHERE schemaname = 'public';")
                fi
            fi
        fi
    fi

    # Transaction happens immediately after
    {
        echo "BEGIN;"
        [ -n "$TRUNCATE_SQL" ] && echo "$TRUNCATE_SQL"
        if [ "$NEEDS_FILTER" -eq 1 ]; then
            echo -e "${CYAN}Filtering missing columns from stream...${NC}" >&2
            awk -v missing_cols="$MISSING_COLUMNS" '
            BEGIN {
                split(missing_cols, temp, " ");
                for (i in temp) missing[temp[i]] = 1;
            }
            /^COPY / {
                in_copy = 1;
                match($0, /\(.*\)/);
                cols_str = substr($0, RSTART + 1, RLENGTH - 2);
                n = split(cols_str, cols_arr, ",");
                
                table = $2;
                new_cols = "";
                delete skip_indices;
                
                for (i=1; i<=n; i++) {
                    col_name = cols_arr[i];
                    # Trim spaces
                    gsub(/^[ \t]+|[ \t]+$/, "", col_name);
                    # Remove quotes for lookup
                    col_lookup = col_name;
                    gsub(/"/, "", col_lookup);
                    
                    full_name = table "." col_lookup;
                    if (full_name in missing) {
                        skip_indices[i] = 1;
                    } else {
                        new_cols = (new_cols == "" ? "" : new_cols ", ") col_name;
                    }
                }
                
                # Rewrite COPY line
                sub(/\(.*\)/, "(" new_cols ")", $0);
                print $0;
                next;
            }
            /^\./ { in_copy = 0; print; next; }
            in_copy {
                n = split($0, row, "\t");
                new_row = "";
                first = 1;
                for (i=1; i<=n; i++) {
                    if (!(i in skip_indices)) {
                        new_row = (first ? "" : new_row "\t") row[i];
                        first = 0;
                    }
                }
                print new_row;
                next;
            }
            { print }
            ' "$RESTORE_FILE"
        else
            cat "$RESTORE_FILE"
        fi
        echo "COMMIT;"
    } | psql "$DB_URL" -v ON_ERROR_STOP=1 >/dev/null

    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}═══════════════════════════════════════${NC}"
        echo -e "${GREEN}      PG-SYNC: RESTORE SUCCESSFUL      ${NC}"
        echo -e "${GREEN}═══════════════════════════════════════${NC}"
    else
        echo -e "${RED}✗ Restore failed (Transaction Rolled Back)${NC}"
    fi
}

main() {
    clear
    echo -e "${BLUE}╔═══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                PG-SYNC                ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════╝${NC}"
    echo -e "${PURPLE}          Developed by XBEAST1          ${NC}"
    echo ""
    ensure_gitignore
    while true; do
        echo -e "1) Backup"
        echo "2) Restore"
        echo "3) Exit"
        echo ""
        read -p "Choice (1-3): " choice
        case $choice in
            1) backup_database; break ;;
            2) restore_database; break ;;
            3) echo -e "${CYAN}Goodbye!${NC}\n"; exit 0 ;;
            *) echo -e "${RED}✗ Invalid choice${NC}" ;;
        esac
    done
}

main