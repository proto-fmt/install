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
    local partitions=("EFI" "Root" "Swap" "Home")
    local examples=("1G" "20G" "4G" "30G")

    # Helper function to convert GB to bytes
    gb_to_bytes() {
        echo "$1 * 1024 * 1024 * 1024" | bc
    }
    # Helper function to convert bytes to GB string
    bytes_to_gb() {
        echo "$1" | awk '{printf "%.1f", $1/1024/1024/1024}'
    }

    # Function to validate and convert size input
    validate_size() {
        local size_input=$1
        local available=$2

        # Strip G suffix and validate number format
        local size=${size_input%G}
        if [[ ! "$size" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            log_warning "Please enter a valid number (e.g. 0.5G, 15G, 250G)"
            return 1
        fi

        local size_bytes=$(gb_to_bytes "$size")
        if ((size_bytes >= available)); then
            log_warning "Size must be less than $(bytes_to_gb "$available")G"
            return 1
        fi

        echo "$size_bytes"
        return 0
    }

    # Get EFI partition size
    while true; do
        local available_bytes=$((total_bytes - used_bytes))
        echo "Available: $(bytes_to_gb "$available_bytes")G"
        read -p "EFI partition size (e.g. 0.5G, 1G, 2G): " size_input

        if size_bytes=$(validate_size "$size_input" "$available_bytes"); then
            EFI_SIZE="$size_bytes"
            used_bytes=$((used_bytes + size_bytes))
            break
        fi
    done

    # Get Root partition size
    while true; do
        local available_bytes=$((total_bytes - used_bytes))
        echo "Available: $(bytes_to_gb "$available_bytes")G"
        read -p "Root partition size (e.g. 30G, 50G, 100G): " size_input

        if size_bytes=$(validate_size "$size_input" "$available_bytes"); then
            ROOT_SIZE="$size_bytes"
            used_bytes=$((used_bytes + size_bytes))
            break
        fi
    done

    # Get Swap partition size
    while true; do
        local available_bytes=$((total_bytes - used_bytes))
        echo "Available: $(bytes_to_gb "$available_bytes")G"
        read -p "Swap partition size (e.g. 4G, 8G, 16G): " size_input

        if size_bytes=$(validate_size "$size_input" "$available_bytes"); then
            SWAP_SIZE="$size_bytes"
            used_bytes=$((used_bytes + size_bytes))
            break
        fi
    done

    # Get Home partition size
    local available_bytes=$((total_bytes - used_bytes))
    while true; do
        echo "Available: $(bytes_to_gb "$available_bytes")G"
        read -p "Home partition size (e.g. 30G, 50G, 100G), or press Enter to use all remaining space: " size_input

        if [[ -z "$size_input" ]]; then
            HOME_SIZE="$available_bytes"
            used_bytes=$total_bytes
            break
        fi

        if size_bytes=$(validate_size "$size_input" "$available_bytes"); then
            HOME_SIZE="$size_bytes"
            used_bytes=$((used_bytes + size_bytes))
            break
        fi
    done

    # Show partition layout summary
    echo -e "\nPartition Layout:"
    print_separator
    printf "%s: %sG\n" \
        "EFI" "$(bytes_to_gb "$EFI_SIZE")" \
        "Root" "$(bytes_to_gb "$ROOT_SIZE")" \
        "Swap" "$(bytes_to_gb "$SWAP_SIZE")" \
        "Home" "$(bytes_to_gb "$HOME_SIZE")"

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
