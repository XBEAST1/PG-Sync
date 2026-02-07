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

MIGRATION_TABLES=(
    "alembic_version"
    "flyway_schema_history"
    "schema_migrations"
    "_prisma_migrations"
    "knex_migrations"
    "knex_migrations_lock"
)

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
    echo -e "${CYAN}Format: postgresql://username:password@host:port/database_name${NC}"
    echo ""
    read -r DB_URL
    
    if [[ ! "$DB_URL" =~ ^postgresql:// ]]; then
        echo -e "${RED}✗ Invalid database URL format${NC}"
        exit 1
    fi
    
    DB_USER=$(echo "$DB_URL" | sed -n 's|postgresql://\([^:]*\):.*|\1|p')
    DB_PASS=$(echo "$DB_URL" | sed -n 's|postgresql://[^:]*:\([^@]*\)@.*|\1|p')
    DB_HOST=$(echo "$DB_URL" | sed -n 's|.*@\([^:]*\):.*|\1|p')
    DB_PORT=$(echo "$DB_URL" | sed -n 's|.*:\([0-9]*\)/.*|\1|p')
    DB_NAME=$(echo "$DB_URL" | sed -n 's|.*/\([^/]*\)$|\1|p')
    
    echo -e "${GREEN}✓ Connection parsed${NC}"
    echo -e "  Host: ${DB_HOST}:${DB_PORT}"
    echo -e "  Database: ${DB_NAME}"
    echo -e "  User: ${DB_USER}"
    echo ""
}

test_db_connection() {
    echo -e "${YELLOW}Testing connection...${NC}"
    export PGPASSWORD="$DB_PASS"
    
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Connection successful${NC}"
        echo ""
        unset PGPASSWORD
        return 0
    else
        echo -e "${RED}✗ Connection failed${NC}"
        echo -e "${YELLOW}Please check your credentials and network access${NC}"
        unset PGPASSWORD
        exit 1
    fi
}

build_migration_pattern() {
    local pattern=""
    for table in "${MIGRATION_TABLES[@]}"; do
        [ -n "$pattern" ] && pattern="$pattern|"
        pattern="$pattern$table"
    done
    echo "$pattern"
}

truncate_all_tables() {
    echo -e "${YELLOW}Truncating all tables...${NC}"
    
    local TRUNCATE_CMD="SELECT 'TRUNCATE TABLE ' || quote_ident(schemaname) || '.' || quote_ident(tablename) || ' CASCADE;' 
                        FROM pg_tables 
                        WHERE schemaname NOT IN ('pg_catalog', 'information_schema');"
    
    local TABLES_TO_TRUNCATE=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "$TRUNCATE_CMD")
    
    if [ -n "$TABLES_TO_TRUNCATE" ]; then
        if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "$TABLES_TO_TRUNCATE" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ All tables truncated${NC}"
        else
            echo -e "${RED}✗ Truncation failed${NC}"
            unset PGPASSWORD
            exit 1
        fi
    else
        echo -e "${YELLOW}! No tables found${NC}"
    fi
    echo ""
}


backup_database() {
    TIMESTAMP=$(date +"%d-%m-%Y_%I-%M%p")
    CURRENT_BACKUP_SET="$BACKUP_BASE_DIR/backup_$TIMESTAMP"
    
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}        PG-SYNC: STARTING BACKUP       ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""
    
    mkdir -p "$CURRENT_BACKUP_SET"
    get_db_connection
    test_db_connection
    export PGPASSWORD="$DB_PASS"
    
    COMMON_FLAGS="--no-owner --no-privileges"
    CLEAN_FLAGS="--clean --if-exists"
    EXCLUDE_TABLES=""
    for table in "${MIGRATION_TABLES[@]}"; do EXCLUDE_TABLES="$EXCLUDE_TABLES -T $table"; done
    
    echo -e "${CYAN}[1/3] Dumping Schema...${NC}"
    if ! pg_dump $CLEAN_FLAGS $COMMON_FLAGS -v -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" --schema-only -f "$CURRENT_BACKUP_SET/schema.sql" 2>&1; then
        echo -e "${RED}✗ Schema backup failed${NC}"
        unset PGPASSWORD
        exit 1
    fi
    
    echo -e "${CYAN}[2/3] Dumping Data (excluding migrations)...${NC}"
    if ! pg_dump $COMMON_FLAGS -v -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" --data-only $EXCLUDE_TABLES -f "$CURRENT_BACKUP_SET/data.sql" 2>&1; then
        echo -e "${RED}✗ Data backup failed${NC}"
        unset PGPASSWORD
        exit 1
    fi
    
    echo -e "${CYAN}[3/3] Dumping Full Backup...${NC}"
    if ! pg_dump $CLEAN_FLAGS $COMMON_FLAGS -v -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$CURRENT_BACKUP_SET/full_data.sql" 2>&1; then
        echo -e "${RED}✗ Full backup failed${NC}"
        unset PGPASSWORD
        exit 1
    fi
    
    unset PGPASSWORD
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}      PG-SYNC: BACKUP SUCCESSFUL       ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}Folder: backup_$TIMESTAMP${NC}"
    echo ""
}

check_if_database_empty() {
    local migration_pattern=$(build_migration_pattern)
    local CHECK_QUERY="SELECT SUM(n_live_tup) FROM pg_stat_user_tables WHERE relname !~ '^($migration_pattern)$';"
    local ROW_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "$CHECK_QUERY" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$ROW_COUNT" || "$ROW_COUNT" -eq 0 ]]
}

# Function to get yes/no confirmation
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

    get_db_connection
    test_db_connection
    
    local DO_TRUNCATE="no"
    if [ "$type_choice" -eq 2 ]; then
        if check_if_database_empty; then 
            echo -e "${GREEN}✓ Database is empty${NC}"
        else
            echo -e "${YELLOW}⚠ Database contains data${NC}"
            if confirm_yes_no "Wipe existing data before restoring?"; then
                DO_TRUNCATE="yes"
            else
                DO_TRUNCATE="no"
            fi
            echo ""
        fi
    fi

    export PGPASSWORD="$DB_PASS"
    
    if [ "$DO_TRUNCATE" == "yes" ]; then
        truncate_all_tables
    else
        echo -e "${CYAN}Restoring $RESTORE_TYPE...${NC}"
        if ! confirm_yes_no "Are you sure you want to proceed with the restore?"; then
            echo -e "${YELLOW}Restore cancelled${NC}"
            unset PGPASSWORD
            exit 0
        fi
    fi

    echo ""
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$RESTORE_FILE" 2>&1; then
        echo ""
        echo -e "${GREEN}═══════════════════════════════════════${NC}"
        echo -e "${GREEN}      PG-SYNC: RESTORE SUCCESSFUL      ${NC}"
        echo -e "${GREEN}═══════════════════════════════════════${NC}"
    else
        echo -e "${RED}✗ Restore failed${NC}"
    fi
    unset PGPASSWORD
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
