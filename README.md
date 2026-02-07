# PG-Sync

**PG-Sync** is a Developer focused, framework-agnostic PostgreSQL backup and restoration tool designed for developers. It features intelligent conflict resolution, automatic migration table exclusion, and a streamlined interactive interface.

## Features

- **High-Performance Backups**
  - **Schema**: Comprehensive database structure snapshots designed for clean-slate restoration.
  - **Data**: Pure table data excluding migration metadata (Alembic, Prisma, etc.).
  - **Full**: Comprehensive snapshots including both schema and data.
- **Intelligent Restoration**
  - **Smart Selection**: Choose from multiple timestamped backup sets.
  - **Constraint Handling**: Uses `CASCADE` truncation to safely clear data while respecting foreign keys.

- **Developer Experience**
  - **Verbose Progress**: Real-time diagnostic output during backup and restoration.
  - **Cross-Framework Support**: Built-in support for Alembic, Flyway, Prisma, Knex, and Rails.
  - **Production Ready**: Portable backups (`--no-owner`, `--no-privileges`).
- **Security & Safety**
  - **Connection Testing**: Validates database connectivity before operations begin.
  - **Error Detection**: All backup operations verify success before proceeding.
  - **Zero Persistence**: Database credentials exist only in current process memory.
  - **Git Safety**: Auto-configures `.gitignore` for the script and data folder.
  - **Atomic Restores**: Uses `ON_ERROR_STOP` to prevent partial data corruption.

## Installation

```bash
# Download the script
wget https://raw.githubusercontent.com/xbeast1/pg-sync/main/pg-sync.sh

# Make it executable
chmod +x pg-sync.sh

# Run the utility
./pg-sync.sh
```

## Prerequisites

The script requires the PostgreSQL client utilities (`psql` and `pg_dump`). These are typically included in the standard client packages for your OS:

**Ubuntu/Debian:**

```bash
sudo apt update && sudo apt install postgresql-client
```

**macOS:**

```bash
brew install postgresql
```

**Arch Linux:**

```bash
sudo pacman -S postgresql
```

**RHEL/CentOS:**

```bash
sudo yum install postgresql
```

## Usage

Run the script and follow the interactive prompts:

```bash
./pg-sync.sh
```

### Connection URL Format

Input your connection string when prompted:
`postgresql://username:password@host:port/database_name`

### Backup Details

Backups are organized into timestamped sets within the `pg-sync-db-backup/` directory. Each operation creates a new folder:

| File            | Type      | Best Used For                             |
| --------------- | --------- | ----------------------------------------- |
| `schema.sql`    | Structure | Replicating structure in new environments |
| `data.sql`      | Content   | Syncing data between existing databases   |
| `full_data.sql` | Complete  | Disaster recovery and full snapshots      |

**Folder Pattern**: `pg-sync-db-backup/backup_DD-MM-YYYY_HH-MMPM/`

**Example Structure:**

```text
pg-sync-db-backup/
├── backup_25-06-2023_01-05AM/
│   ├── data.sql
│   ├── full_data.sql
│   └── schema.sql
├── backup_25-08-2023_03-00AM/
│   └── ...
├── backup_06-10-2023_11-19PM/
│   └── ...
├── backup_01-01-2024_12-00AM/
│   └── ...
├── backup_26-02-2024_01-27AM/
│   └── ...
├── backup_04-02-2026_11-57PM/
│   └── ...
└── backup_07-02-2026_01-30PM/
    └── ...
```

### Restore Operation

The script intelligently handles multiple backup sets and existing data conflicts:

1.  **Select Backup Set**: Choose from a numbered list of available timestamped folders.
2.  **Select Type**: Pick whether to restore Schema, Data, or Full database.
3.  **Conflict Handling**:
    - **Schema/Full**: Automatically drops and recreates objects.
    - **Data**: Checks for existing data and offers a "Smart Wipe" option.

## Troubleshooting

- **Check Connectivity**: Ensure your host and port are accessible.
- **Tools**: If `pg_dump` is missing, refer to the Prerequisites section.
- **Permissions**: The database user must have sufficient privileges to create, drop, truncate, and modify objects in the target schema.

---

**License:** MIT  
**GitHub:** [XBEAST1](https://github.com/xbeast1)  
**Email:** [xbeast1@proton.me](mailto:xbeast1@proton.me)
