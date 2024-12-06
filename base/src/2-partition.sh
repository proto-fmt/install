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

        break
    done

    # Confirm data erasure
    echo -e "${RED}WARNING: All data on $DISK ($(lsblk -ndo SIZE "$DISK")) will be erased!${NC}"
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
    # Get total disk size in bytes and initialize variables
    local total_bytes=$(lsblk -ndo SIZE "$DISK" --bytes)
    local used_bytes=0
    local -A sizes # Associative array to store partition sizes
    local -A partition_info=(
        ["EFI"]="1G false"
        ["Root"]="30G false" 
        ["Swap"]="4G false"
        ["Home"]="30G true"
    )

    # Helper functions
    gb_to_bytes() { 
        # Use bc for floating point arithmetic
        echo "scale=0; $1 * 1024^3 / 1" | bc
    }
    bytes_to_gb() { 
        # Use bc for floating point arithmetic with 1 decimal place
        echo "scale=1; $1 / 1024^3" | bc
    }

    # Function to get and validate partition size
    get_partition_size() {
        local name=$1
        local example=$2
        local allow_empty=$3
        local prompt="$name partition size (e.g. $example): "
        
        [[ "$allow_empty" == "true" ]] && prompt+="or press Enter to use all remaining space"

        while true; do
            local available_bytes=$((total_bytes - used_bytes))
            echo "Available: $(bytes_to_gb "$available_bytes")G"
            read -p "$prompt" size_input

            if [[ -z "$size_input" && "$allow_empty" == "true" ]]; then
                sizes[$name]=$available_bytes
                used_bytes=$total_bytes
                return
            fi

            # Validate size format and convert
            local size=${size_input%G}
            # Allow decimal numbers with optional decimal point
            if [[ ! "$size" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                log_warning "Please enter a valid number (e.g. 0.5G, 15.5G, 250G)"
                continue
            fi

            # Convert to bytes using bc for floating point
            local size_bytes=$(gb_to_bytes "$size")
            if ((size_bytes >= available_bytes)); then
                log_warning "Size must be less than $(bytes_to_gb "$available_bytes")G"
                continue
            fi

            sizes[$name]=$size_bytes
            used_bytes=$((used_bytes + size_bytes))
            break
        done
    }

    # Get sizes for each partition
    for part in "${!partition_info[@]}"; do
        read example allow_empty <<< "${partition_info[$part]}"
        get_partition_size "$part" "$example" "$allow_empty"
    done

    # Export sizes to global variables
    EFI_SIZE=${sizes[EFI]}
    ROOT_SIZE=${sizes[Root]}
    SWAP_SIZE=${sizes[Swap]}
    HOME_SIZE=${sizes[Home]}

    # Show partition layout summary
    echo -e "\nPartition Layout:"
    print_separator
    for part in "${!sizes[@]}"; do
        printf "%s: %sG\n" "$part" "$(bytes_to_gb "${sizes[$part]}")"
    done

    local remaining_bytes=$((total_bytes - used_bytes))
    ((remaining_bytes > 0)) && echo "Remaining unallocated space: $(bytes_to_gb "$remaining_bytes")G"
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
