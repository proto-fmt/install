#!/bin/bash

source helpers.sh  # source the helper functions for logging

# Function to let user select disk
select_disk() {
    # Get list of disks, excluding unwanted devices
    local disks=($(lsblk -dpno NAME | grep -Ev "loop|sr|rom|airootfs|mmcblk.*boot[01]|mmcblk.*rpmb"))

    # Check if any disks were found
    if [ ${#disks[@]} -eq 0 ]; then
        log_error "No suitable disks found"
        return 1
    fi

    # Display available disks with info
    echo "Available disks:"
    echo "----------------"
    local disk_info=()
    for i in "${!disks[@]}"; do
        disk_info[$i]=$(lsblk -dno SIZE,MODEL "${disks[$i]}")
        echo "$((i+1))) ${disks[$i]} (${disk_info[$i]})"
    done
    echo "----------------"

    # Get valid disk selection from user
    local selection
    while true; do
        read -p "Select disk number (1-${#disks[@]}): " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && ((selection >= 1 && selection <= ${#disks[@]})); then
            break
        fi
        log_warning "Please enter a valid number between 1 and ${#disks[@]}"
    done

    DISK="${disks[$((selection-1))]}"
    
    # Confirmation for data erasure
    local disk_info="${disk_info[$((selection-1))]}"
    echo -e "${RED}WARNING: All data on $DISK will be erased!${NC}"
    echo -e "${RED}         $disk_info${NC}"
    
    read -p "Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_error "Operation cancelled by user"
        exit 1
    fi

    log_info "Selected disk: $DISK"
}

# Get partition sizes from user
get_partition_sizes() {
    # Function to validate size format
    validate_size() {
        local size=$1
        local unit=$2  # "M" or "G" or "MG" for both
        [[ "$size" =~ ^[0-9]+[$unit]$ ]]
    }

    # Get EFI partition size
    while true; do
        read -p "Enter EFI partition size (e.g., 512M, 1G): " EFI_SIZE
        if validate_size "$EFI_SIZE" "MG"; then
            break
        fi
        log_warning "Please enter a valid size (e.g., 512M, 1G)"
    done

    # Get root partition size
    while true; do
        read -p "Enter ROOT partition size (e.g., 30G, 50G): " ROOT_SIZE
        if validate_size "$ROOT_SIZE" "G"; then
            break
        fi
        log_warning "Please enter a valid size (e.g., 30G, 50G)"
    done

    # Get swap size
    while true; do
        read -p "Enter SWAP partition size (e.g., 2G, 4G): " SWAP_SIZE
        if validate_size "$SWAP_SIZE" "G"; then
            break
        fi
        log_warning "Please enter a valid size (e.g., 2G, 4G)"
    done

    # Get home partition size (optional)
    while true; do
        read -p "Enter HOME partition size (empty for remaining space, or e.g., 100G): " HOME_SIZE
        if [[ -z "$HOME_SIZE" ]]; then
            log_info "Home partition will use remaining disk space"
            break
        elif validate_size "$HOME_SIZE" "G"; then
            log_info "Home partition will be created with size: $HOME_SIZE"
            break
        else
            log_warning "Please enter a valid size (e.g., 100G) or press Enter for remaining space"
        fi
    done
}

# Create partitions
create_partitions() {
    echo "Creating partitions on $DISK..."
    
    # Clear existing partition table and create new GPT
    if ! (sgdisk -Z "$DISK" && sgdisk -o "$DISK"); then
        log_error "Failed to initialize partition table"
        exit 1
    fi

    # Create all partitions in one command
    if ! sgdisk "$DISK" \
        -n 1:0:+"$EFI_SIZE" -t 1:ef00 -c 1:"EFI" \
        -n 2:0:+"$SWAP_SIZE" -t 2:8200 -c 2:"SWAP" \
        -n 3:0:+"$ROOT_SIZE" -t 3:8300 -c 3:"root" \
        -n 4:0:0 -t 4:8300 -c 4:"home"; then
        log_error "Failed to create partitions"
        exit 1
    fi

    log_success "Partitions created successfully"
}

# Format partitions
format_partitions() {
    echo "Formatting partitions..."
    
    # Format EFI partition
    if ! mkfs.fat -F32 "${DISK}1"; then
        log_error "Failed to format EFI partition"
        exit 1
    fi
    
    # Format swap partition
    if ! mkswap "${DISK}2"; then
        log_error "Failed to format swap partition"
        exit 1
    fi
    
    # Format root partition
    if ! mkfs.ext4 "${DISK}3"; then
        log_error "Failed to format root partition"
        exit 1
    fi

    # Format home partition
    if ! mkfs.ext4 "${DISK}4"; then
        log_error "Failed to format home partition"
        exit 1
    fi
    
    log_success "Partitions formatted successfully"
}

# Mount partitions
mount_partitions() {
    echo "Mounting partitions..."
    
    # Mount root partition
    if ! mount "${DISK}3" /mnt; then
        log_error "Failed to mount root partition"
        exit 1
    fi
    
    # Create and mount home directory
    mkdir -p /mnt/home
    if ! mount "${DISK}4" /mnt/home; then
        log_error "Failed to mount home partition"
        exit 1
    fi
    
    # Create and mount EFI directory
    mkdir -p /mnt/boot/efi
    if ! mount "${DISK}1" /mnt/boot/efi; then
        log_error "Failed to mount EFI partition"
        exit 1
    fi
    
    # Enable swap
    if ! swapon "${DISK}2"; then
        log_error "Failed to enable swap"
        exit 1
    fi
    
    log_success "Partitions mounted successfully"
}

# Main function
main() {
    select_disk
    get_partition_sizes
    create_partitions
    format_partitions
    mount_partitions
    
    log_info "Disk partitioning completed successfully"
    print_separator
}

# Run the main function
main
