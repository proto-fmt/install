#!/bin/bash

clear
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
    echo -e "${RED}WARNING: All data on $DISK will be erased!${NC}"
    echo -e "${RED}         ${disk_info[$((selection-1))]}${NC}"
    read -p "Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_error "Operation cancelled by user"
        return 1
    fi

    log_success "Selected disk: $DISK"
    return 0
}

# Get partition sizes from user
get_partition_sizes() {
    # Get total disk size in MB
    local total_size_mb=$(lsblk -b "$DISK" | awk 'NR==1{print $4/1024/1024}' | cut -d'.' -f1)
    local remaining_mb=$total_size_mb
    
    # Function to validate size format and convert to MB
    validate_size() {
        local size=$1
        local unit=${size: -1}  # Get last character
        local number=${size%[MG]}  # Remove unit
        
        if [[ "$number" =~ ^[0-9]+$ ]] && [[ "$unit" =~ [MG] ]]; then
            if [ "$unit" = "G" ]; then
                echo $((number * 1024))
            else
                echo "$number"
            fi
            return 0
        fi
        return 1
    }

    # Function to get partition size
    get_size() {
        local name=$1
        local unit=$2
        local example=$3
        local var_name=$4
        
        while true; do
            echo "Remaining space: ${remaining_mb}M ($(echo "scale=2; $remaining_mb/1024" | bc)G)"
            read -p "Enter $name partition size (e.g., $example): " size
            if size_mb=$(validate_size "$size"); then
                if [ "$name" = "ENCRYPTED" ] && [ $size_mb -gt $remaining_mb ]; then
                    log_warning "Requested size exceeds remaining space"
                    continue
                fi
                remaining_mb=$((remaining_mb - size_mb))
                eval "$var_name='$size'"
                break
            fi
            log_warning "Please enter a valid size in $unit (e.g., $example)"
        done
    }

    # Get partition sizes
    get_size "EFI" "megabytes" "512M" "EFI_SIZE"
    get_size "ROOT" "gigabytes" "30G" "ROOT_SIZE"
    get_size "SWAP" "gigabytes" "2G" "SWAP_SIZE"
    get_size "ENCRYPTED" "gigabytes" "20G" "CRYPT_SIZE"

    # Get encryption password
    while true; do
        echo
        read -s -p "Enter encryption password: " CRYPT_PASSWORD
        echo
        read -s -p "Confirm encryption password: " CRYPT_PASSWORD_CONFIRM
        echo
        
        if [ "$CRYPT_PASSWORD" = "$CRYPT_PASSWORD_CONFIRM" ] && [ ${#CRYPT_PASSWORD} -ge 8 ]; then
            break
        fi
        log_warning "$([ "$CRYPT_PASSWORD" != "$CRYPT_PASSWORD_CONFIRM" ] && echo "Passwords do not match" || echo "Password must be at least 8 characters long")"
    done

    # Home partition uses remaining space
    HOME_SIZE="${remaining_mb}M"
    log_info "Home partition will use remaining disk space (${remaining_mb}M / $(echo "scale=2; $remaining_mb/1024" | bc)G)"

    # Show summary and ask for confirmation
    echo
    echo "Partition layout summary:"
    echo "------------------------"
    echo "EFI partition:       $EFI_SIZE"
    echo "Root partition:      $ROOT_SIZE" 
    echo "Swap partition:      $SWAP_SIZE"
    echo "Encrypted partition: $CRYPT_SIZE"
    echo "Home partition:      $HOME_SIZE"
    echo "------------------------"
    
    read -p "Do you confirm this partition layout? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_error "Operation cancelled by user"
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
