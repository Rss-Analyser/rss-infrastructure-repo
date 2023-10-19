#!/bin/bash

# Connection details for CockroachDB (replace with your details)
COCKROACH_HOST="your_cockroachdb_host"
COCKROACH_PORT="26257"
COCKROACH_USER="root"

# Check if the 'rss_db' database exists
DB_EXISTS=$(cockroach sql --host=$COCKROACH_HOST --port=$COCKROACH_PORT --user=$COCKROACH_USER -e "SHOW DATABASES LIKE 'rss_db';")

# If the database doesn't exist, set it up
if [[ -z "$DB_EXISTS" ]]; then
    cockroach sql --host=$COCKROACH_HOST --port=$COCKROACH_PORT --user=$COCKROACH_USER  < ./setup_db.sql
fi
