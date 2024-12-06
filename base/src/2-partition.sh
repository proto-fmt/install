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
    local sizes=()
    local partitions=("EFI" "Root" "Swap" "Home")
    local examples=("1G, 0.5G" "5G" "5G" "20G")

    # Helper function to convert GB to bytes
    gb_to_bytes() {
        echo "scale=0; $1*1024*1024*1024/1" | bc
    }

    # Helper function to convert bytes to GB string
    bytes_to_gb() {
        printf "%.1f" $(echo "scale=1; $1/1024/1024/1024" | bc)
    }

    # Get size for each partition
    for i in "${!partitions[@]}"; do
        local is_last=$((i == ${#partitions[@]} - 1))
        
        while true; do
            local available_bytes=$((total_bytes - used_bytes))
            local available_gb=$(bytes_to_gb "$available_bytes")
            
            echo "Available: ${available_gb}G"
            local prompt="${partitions[$i]} partition size (e.g. ${examples[$i]}"
            [[ $is_last ]] && prompt+=", or press Enter to use remaining space"
            read -p "$prompt): " size_input

            # Use remaining space for last partition if Enter pressed
            if [[ $is_last && -z "$size_input" ]]; then
                sizes+=("$available_bytes")
                used_bytes=$total_bytes
                break
            fi

            # Validate input and convert to bytes
            size=${size_input%G}
            if [[ ! "$size" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                log_warning "Please enter a valid number followed by G (e.g. ${examples[$i]})"
                continue
            fi

            local size_bytes=$(gb_to_bytes "$size")
            if ((size_bytes >= available_bytes)); then
                log_warning "Size must be less than ${available_gb}G"
                continue
            fi

            sizes+=("$size_bytes")
            used_bytes=$((used_bytes + size_bytes))
            break
        done
    done

    # Assign partition sizes
    EFI_SIZE="${sizes[0]}"
    ROOT_SIZE="${sizes[1]}" 
    SWAP_SIZE="${sizes[2]}"
    HOME_SIZE="${sizes[3]}"

    # Show partition layout summary
    echo -e "\nPartition Layout:"
    print_separator
    echo "EFI:  $(bytes_to_gb "$EFI_SIZE")G"
    echo "Root: $(bytes_to_gb "$ROOT_SIZE")G"
    echo "Swap: $(bytes_to_gb "$SWAP_SIZE")G"
    echo "Home: $(bytes_to_gb "$HOME_SIZE")G"
    
    local remaining_bytes=$((total_bytes - used_bytes))
    if ((remaining_bytes > 0)); then
        echo "Remaining unallocated space: $(bytes_to_gb "$remaining_bytes")G"
    fi
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
