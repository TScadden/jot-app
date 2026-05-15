#!/bin/bash

# This script allows you to run database commands by number.
# Usage: ./data.sh <number>

if [ -z "$1" ]; then
    echo "Usage: ./data.sh <number>"
    exit 1
fi

COMMAND_FILE="/Users/Tysonn/AndroidStudioProjects/Notel/Admin Coding/Database commands.txt"
ENV_FILE="/Users/Tysonn/AndroidStudioProjects/Notel/jot-server/.env"
NUMBER=$1

# Load environment variables if .env exists
if [ -f "$ENV_FILE" ]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Ignore comments and empty lines, handle lines with =
        if [[ ! "$line" =~ ^# && "$line" =~ = ]]; then
            # Clean up whitespace and export
            line=$(echo "$line" | sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//')
            export "$line"
        fi
    done < "$ENV_FILE"
fi

# Append local SSL cert if it exists (needed for psql to work on this Mac with RDS)
CERT_PATH="/Users/Tysonn/AndroidStudioProjects/Notel/global-bundle.pem"
if [ -f "$CERT_PATH" ]; then
    if [[ "$DATABASE_URL" == *"?"* ]]; then
        DATABASE_URL="${DATABASE_URL}&sslrootcert=${CERT_PATH}&sslmode=verify-full"
    else
        DATABASE_URL="${DATABASE_URL}?sslrootcert=${CERT_PATH}&sslmode=verify-full"
    fi
fi

# Find the command line associated with the number
# 1. Search for the line starting with the number followed by a colon
# 2. Get the next line which contains the actual command in backticks
# 3. Strip the backticks and leading/trailing whitespace
if [ "$NUMBER" -eq 12 ] || [ "$NUMBER" -eq 13 ]; then
    if [ -z "$2" ]; then
        echo "❌ Error: Command $NUMBER requires an email address."
        echo "Usage: ./data.sh $NUMBER user@example.com"
        exit 1
    fi
fi

CMD=$(grep -A 1 "^$NUMBER:" "$COMMAND_FILE" | grep '`' | sed 's/.*`\(.*\)`.*/\1/')

if [ -z "$CMD" ]; then
    echo "❌ Command number $NUMBER not found in $COMMAND_FILE"
    exit 1
fi

echo "🚀 Running command $NUMBER: $CMD"
echo "--------------------------------------------------"
eval "$CMD"
echo "--------------------------------------------------"
echo "✅ Done"
