#!/bin/bash

source helpers.sh  # source the helper functions for logging


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

        # Remove trailing slashes from disk name
        DISK=${DISK%/}
        
        # Validate disk exists
        if ! lsblk "$DISK" &>/dev/null; then
            log_warning "Invalid disk name: $DISK"
            continue
        fi

        # Check for system devices that shouldn't be used
        local system_devices="loop|sr|rom|airootfs" 
        if [[ "$DISK" =~ $system_devices ]]; then
            log_warning "Invalid! System device selected."
            continue
        fi

        # Check disk size
        local MIN_DISK_SIZE=10  # Minimum required disk size in GB
        local disk_size=$(lsblk -ndo SIZE "$DISK" | tr -d 'G')
        if (( disk_size < MIN_DISK_SIZE )); then
            log_warning "Disk size must be at least ${MIN_DISK_SIZE}GB. Selected disk is ${disk_size}GB"
            continue
        fi

        break
    done

    # Confirm data erasure
    echo -e "${RED}WARNING: All data on $DISK (${lsblk -ndo SIZE "$DISK"}) will be erased!${NC}"
    read -p "Continue? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        log_error "Canceled by user"
        return 1
    fi

    log_success "Selected disk: $DISK ($(lsblk -ndo SIZE "$DISK"))"
    return 0
}

# Get partition sizes from user
get_partition_sizes() {
    # Get total disk size in bytes
    local total_bytes=$(lsblk -ndo SIZE "$DISK" --bytes)
    local total_gb=$(printf "%.2f" $(echo "scale=2; $total_bytes/1024/1024/1024" | bc))
    local used_bytes=0

    # Get partition sizes
    local partitions=("EFI" "Root" "Swap")
    local sizes=()

    # Get sizes for each partition
    for part in "${partitions[@]}"; do
        while true; do
            local used_gb=$(printf "%.2f" $(echo "scale=2; $used_bytes/1024/1024/1024" | bc))
            local available_gb=$(printf "%.2f" $(echo "scale=2; ($total_bytes-$used_bytes)/1024/1024/1024" | bc))
            
            echo "Total space: ${total_gb}G"
            echo "Used space: ${used_gb}G"
            echo "Available: ${available_gb}G"
            read -p "${part} partition size (G): " size

            # Validate input
            if [[ ! "$size" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                log_warning "Please enter a valid number"
                continue
            fi

            # Convert input GB to bytes
            local size_bytes=$(echo "scale=0; $size*1024*1024*1024/1" | bc)

            if ((size_bytes >= (total_bytes - used_bytes))); then
                log_warning "Size must be less than ${available_gb}G"
                continue
            fi

            sizes+=("$size_bytes")
            used_bytes=$((used_bytes + size_bytes))
            break
        done
    done

    # Assign variables with byte values
    EFI_SIZE="${sizes[0]}"
    ROOT_SIZE="${sizes[1]}"
    SWAP_SIZE="${sizes[2]}"
    HOME_SIZE="$((total_bytes - used_bytes))"

    # Show summary with GB conversions
    echo
    echo "Partition Layout:"
    print_separator
    echo "EFI:  $(printf "%.2fG" $(echo "scale=2; $EFI_SIZE/1024/1024/1024" | bc))"
    echo "Root: $(printf "%.2fG" $(echo "scale=2; $ROOT_SIZE/1024/1024/1024" | bc))"
    echo "Swap: $(printf "%.2fG" $(echo "scale=2; $SWAP_SIZE/1024/1024/1024" | bc))"
    echo "Home: $(printf "%.2fG" $(echo "scale=2; $HOME_SIZE/1024/1024/1024" | bc)) (remaining space)"
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
