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
    echo "Available disks:"
    print_separator
    lsblk -lpdo NAME,SIZE,TYPE,MODEL
    print_separator

    # Get disk selection and validate
    while true; do
        read -p "Enter disk name (e.g. /dev/sda): " DISK
        
        # Validate disk exists
        if ! lsblk "$DISK" &>/dev/null; then
            log_warning "Invalid disk name: $DISK"
            continue
        fi

        # Check for system devices that shouldn't be used
        local system_devices="loop|sr|rom|airootfs" 
        if [[ "$DISK" =~ $system_devices ]]; then
            log_warning "System device selected. This is not recommended."
            continue
        fi

        # Check disk size
        local min_size=$((10 * 1024 * 1024 * 1024)) # 10GB in bytes
        local disk_size=$(lsblk -dbno SIZE "$DISK")
        if [ "$disk_size" -lt "$min_size" ]; then
            log_warning "Disk is too small. Minimum 10GB required"
            continue
        fi

        break
    done

    # Confirm data erasure
    
    echo -e "${RED}WARNING: All data on $DISK will be erased!${NC}"
    read -p "Continue? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return 1

    log_success "Selected disk: $DISK"
    return 0
}

# Get partition sizes from user
get_partition_sizes() {
    # Get total disk size in bytes and convert to GB
    local total_bytes=$(lsblk -dbno SIZE "$DISK")
    local total_gb=$(echo "scale=2; $total_bytes / (1024 * 1024 * 1024)" | bc)
    local remaining_gb=$total_gb

    echo "Total disk size: ${total_gb}G"
    echo

    # Function to validate and convert partition size
    get_partition_size() {
        local size_prompt=$1
        local max_size=$2
        local var_name=$3

        while true; do
            echo "Remaining space: ${max_size}G"
            read -p "$size_prompt (e.g. ${4}): " size

            if [[ ! "$size" =~ ^[0-9]+[GM]$ ]]; then
                log_warning "Please enter a valid size (e.g. 512M or 1G)"
                continue
            fi

            # Convert to GB for calculations
            local size_gb
            if [[ "$size" =~ M$ ]]; then
                size_gb=$(( ${size%M} / 1024 ))
            else
                size_gb=${size%G}
            fi

            if [ "$size_gb" -ge "$max_size" ]; then
                log_warning "Please enter a valid size less than ${max_size}G"
                continue
            fi

            eval "$var_name='$size'"
            echo "$size_gb"
            break
        done
    }

    # Get partition sizes
    local efi_gb=$(get_partition_size "EFI partition size" "$remaining_gb" "EFI_SIZE" "512M or 1G")
    remaining_gb=$((remaining_gb - efi_gb))
    log_success "EFI partition size set to $EFI_SIZE"

    local root_gb=$(get_partition_size "ROOT partition size" "$remaining_gb" "ROOT_SIZE" "20G or 20480M")
    remaining_gb=$((remaining_gb - root_gb))

    local swap_gb=$(get_partition_size "SWAP partition size" "$remaining_gb" "SWAP_SIZE" "4G or 4096M")
    remaining_gb=$((remaining_gb - swap_gb))

    # Assign remaining space to home
    HOME_SIZE="${remaining_gb}G"

    # Show summary
    echo
    echo "Partition Layout:"
    print_separator
    echo "EFI:  $EFI_SIZE"
    echo "Root: $ROOT_SIZE" 
    echo "Swap: $SWAP_SIZE"
    echo "Home: $HOME_SIZE (remaining space)"
    print_separator

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
