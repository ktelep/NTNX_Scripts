# Prism Central Categories (v4 APIs)

These scripts use Prism Central v4 APIs and PowerShell 7 or later. Supply the Prism Central URL and a `PSCredential` at runtime; credentials are not stored in the scripts.

```powershell
$credential = Get-Credential -UserName admin
$pcUrl = 'https://prism-central.example.com:9440'
```

## Create categories from a file

`CreateCategories.ps1` reads one `key:value` pair per line. Blank lines and lines beginning with `#` are ignored. The script creates missing key/value pairs and reports whether the key and exact pair already exist.

```text
Environment:Production
Environment:Development
Application:Inventory
```

```powershell
./CreateCategories.ps1 -InputFile ./categories.txt -PrismCentralUrl $pcUrl -Credential $credential
```

## Assign a category to a VM

The historical parameter names are retained for consistency with existing callers: `CategoryName` is the v4 category **key**, and `CategoryKey` is the v4 category **value**. The category pair must already exist.

```powershell
./AddCategory.ps1 -VMName my-vm -CategoryName Environment -CategoryKey Production `
    -PrismCentralUrl $pcUrl -Credential $credential
```

## Assign a category to a cluster

```powershell
./AddCategoryCluster.ps1 -ClusterName my-cluster -CategoryName Environment -CategoryKey Production `
    -PrismCentralUrl $pcUrl -Credential $credential
```

## List VMs assigned a category

```powershell
./ListCategoryVMs.ps1 -CategoryName Environment -CategoryKey Production `
    -PrismCentralUrl $pcUrl -Credential $credential
```
