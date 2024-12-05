#!/bin/bash

run_check() {
    local check_function="$1"
    local check_name="$2" 
    local optional_msg="$3"
    local spinner_chars=('/' '-' '\' '|')
    local result output

    echo -n "$check_name... "
    
    # Show spinner in background
    (
        while :; do
            printf '\b%s' "${spinner_chars[i++ % 4]}"
            sleep 0.1
        done
    ) &
    local spinner_pid=$!

    # Run check and capture output and result
    output=$($check_function 2>&1)
    result=$?

    # Kill spinner and show result
    kill $spinner_pid 2>/dev/null
    if ((result == 0)); then
        echo -en "\b\033[32m[OK]\033[0m"
    else
        echo -en "\b\033[31m[FAIL]\033[0m"
    fi

    # Show output if any, otherwise show optional message
    if [[ -n "$output" ]]; then
        echo -e " \033[33m$output\033[0m"
    elif [[ -n "$optional_msg" ]]; then
        echo -e " \033[33m$optional_msg\033[0m"
    else
        echo
    fi

    return $result
}

verify_boot_mode() {
    [[ -d "/sys/firmware/efi/efivar" ]] && return 0
    echo "UEFI mode required"
    return 1
}

check_internet() {
    if ping -c 3 8.8.8.8 >/dev/null; then
        return 0
    fi
    return 1
}

partition_disk() {
    # Show available disks
    echo "Available disks:"
    lsblk
    
    # Ask for disk selection
    read -p "Enter the disk to partition (e.g., sda, nvme0n1): " DISK
    DISK="/dev/${DISK}"
    
    echo "WARNING: This will erase all data on ${DISK}"
    read -p "Are you sure you want to continue? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Aborted by user"
        return 1
    fi

    # Ask for partition sizes
    read -p "Enter EFI partition size (default: 512M): " EFI_SIZE
    EFI_SIZE=${EFI_SIZE:-512M}
    
    read -p "Enter swap partition size (default: 4G): " SWAP_SIZE
    SWAP_SIZE=${SWAP_SIZE:-4G}
    
    read -p "Enter root partition size (default: 50G): " ROOT_SIZE
    ROOT_SIZE=${ROOT_SIZE:-50G}
    
    echo "Home partition will use remaining space"
    read -p "Continue with these settings? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Aborted by user"
        return 1
    fi

    # Create GPT partition table
    parted -s ${DISK} mklabel gpt

    # Create partitions
    echo "Creating partitions..."
    parted -s ${DISK} mkpart primary fat32 1MiB ${EFI_SIZE}
    parted -s ${DISK} set 1 esp on
    parted -s ${DISK} mkpart primary linux-swap ${EFI_SIZE} ${SWAP_SIZE}
    parted -s ${DISK} mkpart primary ext4 ${SWAP_SIZE} ${ROOT_SIZE}
    parted -s ${DISK} mkpart primary ext4 ${ROOT_SIZE} 100%

    # Confirm formatting
    echo "Partitions created. Ready to format partitions."
    read -p "Continue with formatting? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Aborted by user"
        return 1
    fi

    # Format partitions
    echo "Formatting partitions..."
    mkfs.fat -F32 "${DISK}1"
    mkswap "${DISK}2"
    mkfs.ext4 "${DISK}3"
    mkfs.ext4 "${DISK}4"

    # Confirm mounting
    echo "Partitions formatted. Ready to mount partitions."
    read -p "Continue with mounting? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Aborted by user"
        return 1
    fi

    # Mount partitions
    echo "Mounting partitions..."
    mount "${DISK}3" /mnt
    mkdir -p /mnt/boot/efi
    mkdir -p /mnt/home
    mount "${DISK}1" /mnt/boot/efi
    mount "${DISK}4" /mnt/home
    swapon "${DISK}2"

    echo "Disk partitioning completed successfully"
    return 0
}

# Run checks
run_check verify_boot_mode "Checking boot mode"
run_check check_internet "Checking internet connection"
run_check partition_disk "Partitioning disk"
