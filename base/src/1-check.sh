#!/bin/bash

clear

source helpers.sh  # source the helper functions for logging

# Define constants ONLY for this file
MAX_ATTEMPTS=3
WAIT_TIME=2

##### Check if system is booted in UEFI mode
check_uefi() {
    echo "Checking for UEFI boot mode... "
    
    if fw_size=$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null); then
        log_success "${fw_size}-bit UEFI detected"
        return 0
    fi
        
    log_error "System not booted in UEFI mode"
    return 1
}

##### Check internet connection
check_internet() {
    echo "Checking internet connection... "

    # Local function to check connection status
    is_connected() {
        ping -c 1 -W 5 archlinux.org >/dev/null 2>&1
    }

    # Check if already connected
    if is_connected; then
        log_success "Connected"
        return 0
    fi

    log_warning "No internet connection. Attempting to reconnect..."

    # Try to connect multiple times
    for ((i=1; i<=MAX_ATTEMPTS; i++)); do
        echo -n "Attempt $i/$MAX_ATTEMPTS... "
        sleep $WAIT_TIME  # Wait before retrying

        if is_connected; then
            log_success "Connected"
            return 0
        fi  

        echo -e "${RED}Failed${NC}"
    done
   
    log_error "No internet connection after $MAX_ATTEMPTS attempts"
    return 1
}

##### Check system clock synchronization
check_clock() {
    echo "Checking system clock synchronization... "

    # Local function to check sync status
    is_clock_synced() {
        timedatectl show --property=NTPSynchronized --value | grep -q "yes"
    }

    # Check if already synced
    if is_clock_synced; then
        log_success "System clock is synchronized"
        return 0
    fi
    
    log_warning "System clock is not synchronized. Attempting to fix..."
    
    # Try to sync multiple times
    for ((i=1; i<=MAX_ATTEMPTS; i++)); do
        echo -n "Attempt $i/$MAX_ATTEMPTS... "
        timedatectl set-ntp true >/dev/null 2>&1
        sleep $WAIT_TIME

        if is_clock_synced; then
            log_success "System clock successfully synchronized"
            return 0
        fi  

        echo -e "${RED}Failed${NC}"
    done
    
    log_error "Could not synchronize clock after $MAX_ATTEMPTS attempts"
    return 1
}

# Run system checks
run_checks() {
    local checks=("check_uefi" "check_internet" "check_clock")
    
    for check in "${checks[@]}"; do
        if ! $check; then
            exit 1         
        fi
        print_separator
    done
}

# Run all checks
run_checks

# Final message indicating all checks passed
log_info "All system checks passed successfully. Proceeding with the next steps..."