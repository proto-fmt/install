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

    while true; do
        read -p "Enter disk name (e.g. /dev/sda): " DISK
        DISK=${DISK%/} # Remove trailing slashes
        
        [[ ! -b "$DISK" ]] && { log_warning "Invalid disk name: $DISK"; continue; }

        # Check for system devices
        [[ "$DISK" =~ loop|sr|rom|airootfs ]] && { log_warning "Invalid! System device selected."; continue; }

        break
    done

    echo -e "${RED}WARNING: All data on $DISK ($(lsblk -ndo SIZE "$DISK")) will be erased!${NC}"
    read -p "Continue? (y/n): " confirm
    [[ "$confirm" != "y" ]] && { log_error "Canceled by user"; return 1; }

    log_success "Selected disk: $DISK ($(lsblk -ndo SIZE "$DISK"))"
    return 0
}

# Get partition sizes from user
get_partition_sizes() {
    local total_bytes=$(lsblk -ndo SIZE "$DISK" --bytes)
    local used_bytes=0
    local -A sizes partition_info=(
        ["EFI"]="1G false"
        ["Root"]="30G false"
        ["Swap"]="4G false" 
        ["Home"]="30G true"
    )

    gb_to_bytes() { echo "scale=0; $1 * 1024^3" | bc; }
    bytes_to_gb() { echo "scale=1; $1 / 1024^3" | bc; }

    get_partition_size() {
        local name=$1 example=$2 allow_empty=$3
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

            local size=${size_input%G}
            [[ ! "$size" =~ ^[0-9]+([.][0-9]+)?$ ]] && {
                log_warning "Please enter a valid number (e.g. 0.5G, 15.5G, 250G)"
                continue
            }

            local size_bytes=$(gb_to_bytes "$size")
            ((size_bytes >= available_bytes)) && {
                log_warning "Size must be less than $(bytes_to_gb "$available_bytes")G"
                continue
            }

            sizes[$name]=$size_bytes
            used_bytes=$((used_bytes + size_bytes))
            break
        done
    }

    for part in "${!partition_info[@]}"; do
        read example allow_empty <<< "${partition_info[$part]}"
        get_partition_size "$part" "$example" "$allow_empty"
    done

    # Export sizes
    EFI_SIZE=${sizes[EFI]}
    ROOT_SIZE=${sizes[Root]}
    SWAP_SIZE=${sizes[Swap]}
    HOME_SIZE=${sizes[Home]}

    # Show summary
    echo -e "\nPartition Layout:"
    print_separator
    for part in "${!sizes[@]}"; do
        printf "%s: %sG\n" "$part" "$(bytes_to_gb "${sizes[$part]}")"
    done

    local remaining_bytes=$((total_bytes - used_bytes))
    ((remaining_bytes > 0)) && echo "Remaining unallocated space: $(bytes_to_gb "$remaining_bytes")G"
    print_separator

    read -p "Confirm layout? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { log_error "Operation cancelled"; exit 1; }

    log_success "Partition layout confirmed"
}

create_partitions() {
    echo "Creating partitions on $DISK..."
    
    # Initialize GPT
    (sgdisk -Z "$DISK" && sgdisk -o "$DISK") || { log_error "Failed to initialize partition table"; exit 1; }

    # Create partitions
    sgdisk "$DISK" \
        -n 1:0:+"$EFI_SIZE" -t 1:ef00 -c 1:"EFI" \
        -n 2:0:+"$SWAP_SIZE" -t 2:8200 -c 2:"SWAP" \
        -n 3:0:+"$ROOT_SIZE" -t 3:8300 -c 3:"root" \
        -n 4:0:0 -t 4:8300 -c 4:"home" || { log_error "Failed to create partitions"; exit 1; }

    log_success "Partitions created successfully"
}

format_partitions() {
    echo "Formatting partitions..."
    
    mkfs.fat -F32 "${DISK}1" || { log_error "Failed to format EFI partition"; exit 1; }
    mkswap "${DISK}2" || { log_error "Failed to format swap partition"; exit 1; }
    mkfs.ext4 "${DISK}3" || { log_error "Failed to format root partition"; exit 1; }
    mkfs.ext4 "${DISK}4" || { log_error "Failed to format home partition"; exit 1; }
    
    log_success "Partitions formatted successfully"
}

mount_partitions() {
    echo "Mounting partitions..."
    
    mount "${DISK}3" /mnt || { log_error "Failed to mount root partition"; exit 1; }
    
    mkdir -p /mnt/{home,boot/efi}
    mount "${DISK}4" /mnt/home || { log_error "Failed to mount home partition"; exit 1; }
    mount "${DISK}1" /mnt/boot/efi || { log_error "Failed to mount EFI partition"; exit 1; }
    swapon "${DISK}2" || { log_error "Failed to enable swap"; exit 1; }
    
    log_success "Partitions mounted successfully"
}

main() {
    select_disk || exit 1
    get_partition_sizes
    create_partitions
    format_partitions
    mount_partitions
    
    log_info "Disk partitioning completed successfully"
    print_separator
}

main
