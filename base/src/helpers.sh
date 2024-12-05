#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Functions
log_success() {
    echo -e "${GREEN}[OK] ${NC}$1"
}

log_error() {
    echo -e "${RED}[FAIL] ${NC}$1"
}

log_warning() {
    echo -e "${YELLOW}[WARN] ${NC}$1"
}

log_info() {
    echo -e "${BLUE}[INFO] ${NC}$1"
}

# Print a separator line
print_separator() {
    echo "--------------------------------"
}
