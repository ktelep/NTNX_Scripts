# VLAN Networks

`CreateAdvancedNetworks.ps1` creates VLAN subnet configurations in Prism Central using the Networking v4.4 API. Advanced networking is the default and requires the network controller to be deployed; use `-NetworkMode Basic` to create a basic VLAN network. The script requires PowerShell 7 or later. Provide Prism Central credentials at runtime; credentials are not stored in the script.

```powershell
$credential = Get-Credential -UserName admin
$pcUrl = 'https://prism-central.example.com:9440'
```

## Input file

Use one `network_name:VLANID:vswitch_name` entry per line. Blank lines and lines beginning with `#` are ignored. VLAN IDs must be between 1 and 4094.

```text
# Name:VLAN ID:virtual switch
Production:120:vs0
Development:121:vs0
Storage:220:vs1
```

## Create networks

The script resolves the cluster by name, scopes the virtual switch lookup to that cluster, and creates each network as an advanced VLAN subnet by default. It waits for each asynchronous Prism Central task to finish and reports task failures. If a subnet with the same name already exists on that cluster, it is skipped.

```powershell
./CreateAdvancedNetworks.ps1 -ClusterName 'my-cluster' -InputFile './networks.txt' `
    -PrismCentralUrl $pcUrl -Credential $credential
```

To create basic VLAN networks instead, specify `-NetworkMode Basic`:

```powershell
./CreateAdvancedNetworks.ps1 -ClusterName 'my-cluster' -InputFile './networks.txt' `
    -PrismCentralUrl $pcUrl -Credential $credential -NetworkMode Basic
```
