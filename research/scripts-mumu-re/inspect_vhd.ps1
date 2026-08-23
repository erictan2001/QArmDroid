try {
    $vhdPath = "C:\Program Files\Netease\MuMuPlayer\vms\base.madoa\boot.vhdx"
    $v = Mount-VHD -Path $vhdPath -ReadOnly -PassThru
    $diskNum = $v.DiskNumber
    Write-Host "Mounted Disk Number: $diskNum"
    $parts = Get-Partition -DiskNumber $diskNum
    $parts | Format-Table -AutoSize
    Dismount-VHD -Path $vhdPath
} catch {
    Write-Error $_
}
