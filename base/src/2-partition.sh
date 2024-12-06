#!/bin/bash

source helpers.sh  # source the helper functions for logging


# Global variable.
# Only used in this file. 
# Don't edit.
DISK="" # Disk name (e.g. /dev/sda)


# Function to let user select disk
select_disk() {
    clear

    # Show available disks
    print_separator
    echo "Available disks:"
    lsblk -lpdo NAME,SIZE,TYPE,MODEL
    print_separator

    # Get disk selection
    read -p "Enter disk name (e.g. /dev/sda): " DISK

    # Validate disk exists
    if ! lsblk "$DISK" &>/dev/null; then
        log_error "Invalid disk name: $DISK"
        return 1
    fi

    # Check for system devices that shouldn't be used
    local system_devices="loop|sr|rom|airootfs"
    if [[ "$DISK" =~ $system_devices ]]; then
        log_error "System device selected. This is not recommended."
        return 1
    fi

    # Check disk size
    local min_size=$((10 * 1024 * 1024 * 1024)) # 10GB in bytes
    local disk_size=$(lsblk -dbno SIZE "$DISK")
    if [ "$disk_size" -lt "$min_size" ]; then
        log_error "Disk is too small. Minimum 10GB required"
        return 1
    fi

    # Confirm data erasure
    print_separator
    echo -e "${RED}WARNING: All data on $DISK will be erased!${NC}"
    read -p "Continue? (y/n): " confirm
    print_separator
    [[ "$confirm" != "y" ]] && return 1

    log_success "Selected disk: $DISK"
    return 0
}

# Get partition sizes from user
get_partition_sizes() {
    # Get total disk size in bytes and convert to GB/MB
    local total_bytes=$(lsblk -dbno SIZE "$DISK")
    local total_gb=$((total_bytes / 1024 / 1024 / 1024))
    local remaining_gb=$total_gb
    
    echo "Total disk size: ${total_gb}G"
    echo

    # Get EFI size
    while true; do
        echo "Remaining space: ${remaining_gb}G"
        read -p "EFI partition size (e.g. 512M or 1G): " efi_size
        if [[ "$efi_size" =~ ^[0-9]+[GM]$ ]]; then
            EFI_SIZE="$efi_size"
            # Convert to GB for calculations
            if [[ "$efi_size" =~ M$ ]]; then
                local efi_gb=$(( ${efi_size%M} / 1024 ))
            else
                local efi_gb=${efi_size%G}
            fi
            remaining_gb=$((remaining_gb - efi_gb))
            break
        fi
        log_warning "Please enter a valid size (e.g. 512M or 1G)"
    done
    log_success "EFI partition size set to $EFI_SIZE"

    # Get root size
    while true; do
        echo "Remaining space: ${remaining_gb}G"
        read -p "ROOT partition size (e.g. 20G or 20480M): " root_size
        if [[ "$root_size" =~ ^[0-9]+[GM]$ ]]; then
            ROOT_SIZE="$root_size"
            # Convert to GB for calculations
            if [[ "$root_size" =~ M$ ]]; then
                local root_gb=$(( ${root_size%M} / 1024 ))
            else
                local root_gb=${root_size%G}
            fi
            if [ "$root_gb" -lt "$remaining_gb" ]; then
                remaining_gb=$((remaining_gb - root_gb))
                break
            fi
        fi
        log_warning "Please enter a valid size less than ${remaining_gb}G"
    done

    # Get swap size 
    while true; do
        echo "Remaining space: ${remaining_gb}G"
        read -p "SWAP partition size (e.g. 4G or 4096M): " swap_size
        if [[ "$swap_size" =~ ^[0-9]+[GM]$ ]]; then
            SWAP_SIZE="$swap_size"
            # Convert to GB for calculations
            if [[ "$swap_size" =~ M$ ]]; then
                local swap_gb=$(( ${swap_size%M} / 1024 ))
            else
                local swap_gb=${swap_size%G}
            fi
            if [ "$swap_gb" -lt "$remaining_gb" ]; then
                remaining_gb=$((remaining_gb - swap_gb))
                break
            fi
        fi
        log_warning "Please enter a valid size less than ${remaining_gb}G"
    done

    # Assign remaining space to home
    HOME_SIZE="${remaining_gb}G"

    # Show summary
    echo
    echo "Partition Layout:"
    echo "----------------"
    echo "EFI:  $EFI_SIZE"
    echo "Root: $ROOT_SIZE" 
    echo "Swap: $SWAP_SIZE"
    echo "Home: $HOME_SIZE (remaining space)"
    echo "----------------"

    read -p "Confirm layout? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_error "Operation cancelled"
        exit 1
    fi

    log_success "Partition layout confirmed"
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
    if ! select_disk; then
        exit 1
    fi
    get_partition_sizes
    create_partitions
    format_partitions
    mount_partitions
    
    log_info "Disk partitioning completed successfully"
    print_separator
}

# Run the main function
main
