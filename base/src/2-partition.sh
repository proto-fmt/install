#!/bin/bash

source helpers.sh  # source the helper functions for logging

# Function to let user select disk
select_disk() {
    # Get list of disks, excluding unwanted devices
    local disks=($(lsblk -dpno NAME | grep -Ev "loop|sr|rom|airootfs|mmcblk.*boot[01]|mmcblk.*rpmb"))

    # Check if any disks were found
    if [ ${#disks[@]} -eq 0 ]; then
        log_error "No suitable disks found"
        exit 1
    fi

    # Display available disks
    echo "Available disks:"
    echo "----------------"
    local i=1
    for disk in "${disks[@]}"; do
        local disk_info=$(lsblk -dno SIZE,MODEL "$disk")
        echo "$i) $disk ($disk_info)"
        ((i++))
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
    
    # Get disk info for confirmation
    local disk_size=$(lsblk -dno SIZE "$DISK")
    local disk_model=$(lsblk -dno MODEL "$DISK")
    
    # Double confirmation for data erasure
    echo -e "${RED}WARNING: All data on $DISK will be erased!${NC}"
    echo -e "${RED}         Size: $disk_size${NC}"
    echo -e "${RED}         Model: $disk_model${NC}"
    
    read -p "Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_error "Operation cancelled by user"
        exit 1
    fi

    log_info "Selected disk: $DISK"
}

# Get partition sizes from user
get_partition_sizes() {
    # Get EFI partition size
    while true; do
        read -p "Enter EFI partition size (e.g., 512M, 1G): " EFI_SIZE
        if [[ "$EFI_SIZE" =~ ^[0-9]+[MG]$ ]]; then
            break
        fi
        log_warning "Please enter a valid size (e.g., 512M, 1G)"
    done

    # Get root partition size
    while true; do
        read -p "Enter root partition size (e.g., 30G, 50G): " ROOT_SIZE
        if [[ "$ROOT_SIZE" =~ ^[0-9]+[G]$ ]]; then
            break
        fi
        log_warning "Please enter a valid size (e.g., 30G, 50G)"
    done

    # Get swap size
    while true; do
        read -p "Enter swap partition size (e.g., 2G, 4G): " SWAP_SIZE
        if [[ "$SWAP_SIZE" =~ ^[0-9]+[G]$ ]]; then
            break
        fi
        log_warning "Please enter a valid size (e.g., 2G, 4G)"
    done

    
    # Get home partition size (optional)
    while true; do
        read -p "Enter home partition size (empty for remaining space, or e.g., 100G): " HOME_SIZE
        if [[ -z "$HOME_SIZE" ]]; then
            log_info "Home partition will use remaining disk space"
            break
        elif [[ "$HOME_SIZE" =~ ^[0-9]+[G]$ ]]; then
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
    
    # Clear existing partition table
    if ! sgdisk -Z $DISK; then
        log_error "Failed to clear partition table"
        exit 1
    fi

    # Create new GPT partition table
    if ! sgdisk -o $DISK; then
        log_error "Failed to create new GPT partition table"
        exit 1
    fi

    # Create EFI partition
    if ! sgdisk -n 1:0:+$EFI_SIZE -t 1:ef00 -c 1:"EFI" $DISK; then
        log_error "Failed to create EFI partition"
        exit 1
    fi
    
    # Create swap partition
    if ! sgdisk -n 2:0:+$SWAP_SIZE -t 2:8200 -c 2:"swap" $DISK; then
        log_error "Failed to create swap partition"
        exit 1
    fi
    
    # Create root partition
    if ! sgdisk -n 3:0:+$ROOT_SIZE -t 3:8300 -c 3:"root" $DISK; then
        log_error "Failed to create root partition"
        exit 1
    fi

    # Create home partition (use remaining space)
    if ! sgdisk -n 4:0:0 -t 4:8300 -c 4:"home" $DISK; then
        log_error "Failed to create home partition"
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
