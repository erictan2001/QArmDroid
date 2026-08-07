# PowerShell script to launch the ARM64 Android Emulator
# Configured for Snapdragon X Elite (ARM64 Windows Host)

$QEMU_BIN = "C:\msys64\clangarm64\bin\qemu-system-aarch64.exe"
$IMG_DIR = ".\aosp_cf_arm64_only_phone-img"
$GENERIC_RAMDISK = "$IMG_DIR\out_init\ramdisk"
$VENDOR_RAMDISK = "$IMG_DIR\out_vendor\vendor_ramdisk"
$FINAL_INITRD = "$IMG_DIR\combined_initrd.img"

# --- STEP 1: Bootconfig Preparation ---
Write-Host "Preparing Bootconfig..."
# Explicitly targeting PCI 01.0 for the Super device
$bc_text = @"
androidboot.boot_devices = "pci0000:00/0000:00:01.0"
androidboot.hardware = "cutf_cvm"
androidboot.fstab_suffix = "cf.virtio"
androidboot.selinux = "permissive"
androidboot.verifiedbootstate = "orange"
androidboot.force_normal_boot = "1"
"@

$bc_bytes = [System.Text.Encoding]::ASCII.GetBytes($bc_text + "`n")
while (($bc_bytes.Length % 4) -ne 0) { $bc_bytes += [byte]0 }
[uint32]$checksum = 0
foreach ($b in $bc_bytes) { $checksum += $b }
$footer = [System.BitConverter]::GetBytes([uint32]$bc_bytes.Length) + `
          [System.BitConverter]::GetBytes($checksum) + `
          [System.Text.Encoding]::ASCII.GetBytes("#BOOTCONFIG`n")

# --- STEP 2: Merge Everything ---
Write-Host "Merging Ramdisks..."
$gen_bytes = [System.IO.File]::ReadAllBytes($GENERIC_RAMDISK)
$ven_bytes = [System.IO.File]::ReadAllBytes($VENDOR_RAMDISK)
[System.IO.File]::WriteAllBytes($FINAL_INITRD, ($gen_bytes + $ven_bytes + $bc_bytes + $footer))

# --- STEP 3: Launch QEMU ---
Write-Host "Launching QEMU (WHPX + Venus)..."

& $QEMU_BIN `
  -accel whpx `
  -cpu host `
  -machine virt,gic-version=3,highmem=on `
  -m 4G -smp 4 `
  -kernel "$IMG_DIR\out\kernel" `
  -initrd $FINAL_INITRD `
  -drive "file=file:$IMG_DIR\super.img,format=raw,if=none,id=super" `
  -device virtio-blk-pci,drive=super,addr=01.0 `
  -drive "file=file:$IMG_DIR\userdata.img,format=raw,if=none,id=userdata" `
  -device virtio-blk-pci,drive=userdata,addr=02.0 `
  -drive "file=file:$IMG_DIR\vbmeta.img,format=raw,if=none,id=vbmeta" `
  -device virtio-blk-pci,drive=vbmeta,addr=03.0 `
  -drive "file=file:$IMG_DIR\vbmeta_system.img,format=raw,if=none,id=vbmeta_sys" `
  -device virtio-blk-pci,drive=vbmeta_sys,addr=04.0 `
  -device virtio-net-pci,netdev=net0,addr=05.0 `
  -netdev user,id=net0 `
  -device virtio-gpu-gl-pci,blob=on,venus=on,hostmem=512M,addr=06.0 `
  -display sdl,gl=on `
  -device virtio-mouse-pci `
  -device virtio-keyboard-pci `
  -serial stdio `
  -append "pci=realloc console=ttyAMA0 root=/dev/ram0"
