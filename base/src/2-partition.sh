#!/bin/bash

source helpers.sh  # source the helper functions for logging

# Function to let user select disk
select_disk() {
    # Get list of available disks
    local disks=($(lsblk -dpno NAME | grep -v "loop" | grep -v "sr"))
    
    if [ ${#disks[@]} -eq 0 ]; then
        log_error "No suitable disks found"
        exit 1
    }

    echo "Available disks:"
    echo "----------------"
    local i=1
    for disk in "${disks[@]}"; do
        echo "$i) $disk ($(lsblk -dno SIZE,MODEL $disk))"
        ((i++))
    done
    echo "----------------"

    local selection
    while true; do
        read -p "Select disk number (1-${#disks[@]}): " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#disks[@]}" ]; then
            break
        fi
        log_warning "Please enter a valid number between 1 and ${#disks[@]}"
    done

    DISK="${disks[$((selection-1))]}"
    
    # Double confirmation due to destructive operation
    echo -e "${RED}WARNING: All data on $DISK will be erased!${NC}"
    echo -e "${RED}         Size: $(lsblk -dno SIZE $DISK)${NC}"
    echo -e "${RED}         Model: $(lsblk -dno MODEL $DISK)${NC}"
    
    local confirm
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

    # Inform about home partition
    log_info "Home partition will use all remaining disk space"

    # Get swap size
    while true; do
        read -p "Enter swap partition size (e.g., 2G, 4G): " SWAP_SIZE
        if [[ "$SWAP_SIZE" =~ ^[0-9]+[G]$ ]]; then
            break
        fi
        log_warning "Please enter a valid size (e.g., 2G, 4G)"
    done
}

# Create partitions
create_partitions() {
    echo "Creating partitions on $DISK..."
    
    # Clear existing partition table
    sgdisk -Z $DISK

    # Create new GPT partition table
    sgdisk -o $DISK

    # Create EFI partition
    sgdisk -n 1:0:+$EFI_SIZE -t 1:ef00 -c 1:"EFI" $DISK
    
    # Create swap partition
    sgdisk -n 2:0:+$SWAP_SIZE -t 2:8200 -c 2:"swap" $DISK
    
    # Create root partition
    sgdisk -n 3:0:+$ROOT_SIZE -t 3:8300 -c 3:"root" $DISK

    # Create home partition (use remaining space)
    sgdisk -n 4:0:0 -t 4:8300 -c 4:"home" $DISK

    log_success "Partitions created successfully"
}

# Format partitions
format_partitions() {
    echo "Formatting partitions..."
    
    # Format EFI partition
    mkfs.fat -F32 "${DISK}1"
    
    # Format swap partition
    mkswap "${DISK}2"
    
    # Format root partition
    mkfs.ext4 "${DISK}3"

    # Format home partition
    mkfs.ext4 "${DISK}4"
    
    log_success "Partitions formatted successfully"
}

# Mount partitions
mount_partitions() {
    echo "Mounting partitions..."
    
    # Mount root partition
    mount "${DISK}3" /mnt
    
    # Create and mount home directory
    mkdir -p /mnt/home
    mount "${DISK}4" /mnt/home
    
    # Create and mount EFI directory
    mkdir -p /mnt/boot/efi
    mount "${DISK}1" /mnt/boot/efi
    
    # Enable swap
    swapon "${DISK}2"
    
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


