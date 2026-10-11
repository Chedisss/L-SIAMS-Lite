# Prints this PC's address on the school network, one per line.
#
# The adapter with a default gateway is the one on the school network. The
# virtual adapters VirtualBox, VMware, Hyper-V and WSL add have none, and the
# first "IPv4 Address" in ipconfig is often one of theirs.
Get-NetIPConfiguration -ErrorAction SilentlyContinue |
    Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
    ForEach-Object { $_.IPv4Address.IPAddress } |
    Where-Object { $_ -and $_ -notlike '169.254.*' }
