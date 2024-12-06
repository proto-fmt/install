#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
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
    echo -e "${CYAN}[INFO] ${NC}$1"
}

# Print a separator line
print_separator() {
    echo "--------------------------------"
}
