# Nutanix Prism Central API examples in Perl

This directory contains modular, read-oriented inventory examples and explicit AHV VM/NIC CRUD examples. The examples use Prism Central v4 APIs and do not use Prism Element endpoints.

## Contents

- `lib/NTNX/PC/Client.pm` — HTTPS, Basic authentication, request IDs, OData query escaping, collection pagination, task polling, and response ETag extraction.
- `lib/NTNX/PC/AHV.pm` — AHV VM and VM NIC operations.
- `lib/NTNX/PC/Inventory.pm` — inventory resource endpoint map.
- `lib/NTNX/PC/Output.pm` — JSON and CSV output helpers. Nested hashes become dotted CSV columns; nested arrays are serialized as JSON in a cell.
- `examples/inventory.pl` — list AHV VMs, volume groups and their disks, subnets, VPCs, or physical cluster disks.
- `examples/vm_crud.pl` — VM list/get/create/update/delete.
- `examples/nic_crud.pl` — VM NIC get/create/update/delete.
- `t/` — offline tests with a mocked HTTP transport.

## Requirements

Perl 5.26 or later is recommended. Install the modules in `cpanfile` with your preferred Perl dependency manager. On Fedora/RHEL-family systems, typical RPMs are `perl-HTTP-Tiny`, `perl-IO-Socket-SSL`, `perl-JSON-PP`, `perl-MIME-Base64`, `perl-FindBin`, `perl-Test-Simple`, and `perl-Test-Harness`.

From this directory, local tests can be run without connecting to a cluster:

```sh
perl -Ilib t/01_output.t
perl -Ilib t/02_client.t
perl -Ilib t/03_ahv_etag.t
```

Or use `prove -Ilib t` if `prove` is installed.

## Configure Prism Central

Supply credentials through the environment. The password should not be placed in a script, a JSON body file, or a command-line argument.

```sh
export NTNX_PC_URL='https://prism-central.example.com:9440'
export NTNX_PC_USERNAME='admin'
read -s NTNX_PC_PASSWORD
export NTNX_PC_PASSWORD
```

TLS certificate verification is enabled by default. For a private CA, set `NTNX_PC_CA_FILE` to the CA certificate path. Each example also accepts `--insecure`, which disables TLS certificate and hostname verification for that invocation. Use this only when you explicitly accept the risk of connecting without server identity verification; prefer a trusted CA in normal use.

## Inventory examples

All inventory examples support JSON or CSV. JSON preserves the API’s nested resource structure. CSV uses the union of returned field paths as columns, sorts the columns, uses dotted paths for nested hashes, and places nested arrays in JSON-encoded cells.

```sh
perl examples/inventory.pl --resource vms --format json
perl examples/inventory.pl --resource vms --format csv
perl examples/inventory.pl --resource vms --format json --insecure
perl examples/inventory.pl --resource volume_groups --format csv
perl examples/inventory.pl --resource volume_group_disks --parent-id '<VG_EXT_ID>' --format csv
perl examples/inventory.pl --resource subnets --format json
perl examples/inventory.pl --resource vpcs --format csv
perl examples/inventory.pl --resource physical_disks --format json
```

Use optional OData filter/select expressions to limit fields or records; the client will URL-encode the expression and follow all collection pages (limit 100 by default, API maximum 100).

```sh
perl examples/inventory.pl --resource vms --filter "powerState eq 'ON'" \
  --select 'extId,name,powerState,memorySizeBytes' --format csv
```

The volume group disk collection is scoped to a volume group and therefore requires `--parent-id` with its external ID. The inventory endpoints are AHV VM v4.3, Volume v4.3, Networking v4.4, and Cluster Management v4.3. Confirm availability against the customer’s Prism Central release and permissions.

## VM CRUD examples

Mutating commands require `--confirm` to make the write explicit. Create accepts the full API body from a JSON file. For example, start with a copy of a VM body obtained using the API documentation, then adjust the cluster, image/disk, subnet, and other IDs for the target environment.

```sh
perl examples/vm_crud.pl --action list
perl examples/vm_crud.pl --action get --id '<VM_EXT_ID>'
perl examples/vm_crud.pl --action create --body-json ./create-vm.json --confirm
perl examples/vm_crud.pl --action update --id '<VM_EXT_ID>' --name 'renamed-vm' --confirm
perl examples/vm_crud.pl --action update --id '<VM_EXT_ID>' \
  --body-json ./vm-changes.json --confirm
perl examples/vm_crud.pl --action delete --id '<VM_EXT_ID>' --confirm
```

The update file is a JSON object containing fields to change. The module first GETs the current VM, merges those top-level fields into its full representation, removes `_etag` and `links`, and sends the full body as a conditional PUT. Set `name` to override/add the name field. Supply nested field values as complete nested objects when changing a nested property.

## VM NIC CRUD examples

NIC create JSON must include valid backing and network/subnet references from the target Prism Central. Update JSON contains the fields to change and is merged into the fetched NIC representation.

```sh
perl examples/nic_crud.pl --action get --vm-id '<VM_EXT_ID>' --id '<NIC_EXT_ID>'
perl examples/nic_crud.pl --action create --vm-id '<VM_EXT_ID>' \
  --body-json ./create-nic.json --confirm
perl examples/nic_crud.pl --action update --vm-id '<VM_EXT_ID>' --id '<NIC_EXT_ID>' \
  --body-json ./nic-changes.json --confirm
perl examples/nic_crud.pl --action delete --vm-id '<VM_EXT_ID>' \
  --id '<NIC_EXT_ID>' --confirm
```

## ETags and asynchronous operations

- The AHV VM update API (`PUT /api/vmm/v4.3/ahv/config/vms/{extId}`) requires `If-Match`. The script GETs the VM immediately before update and uses its `ETag` response header (falling back to a body `_etag`). HTTP 428 indicates a missing condition; HTTP 412 indicates the resource changed and the fetched version is stale.
- VM NIC update (`PUT .../vms/{vmExtId}/nics/{extId}`) likewise requires an ETag from a GET of that NIC.
- The documented VM and NIC create/delete schemas require a unique `NTNX-Request-Id`, which the client generates, but do not require `If-Match`.
- Create and other write APIs may return task information. The low-level client includes `wait_for_task`; use the returned task external ID with it when the response represents an asynchronous task. Task polling uses the Prism v4.4 task endpoint.

The CRUD scripts modify or delete real resources. `--confirm` prevents an accidental write from a copied command, but it is not a substitute for choosing a disposable test VM and reviewing the JSON body. The automated tests use mocked responses and do not change cluster resources.

## API references

- [Nutanix Developer Portal](https://developers.nutanix.com/)
- AHV VM configuration v4.3: `/api/vmm/v4.3/ahv/config/vms`
- Volume groups v4.3: `/api/volumes/v4.3/config/volume-groups`
- Networking subnets and VPCs v4.4: `/api/networking/v4.4/config/subnets` and `/api/networking/v4.4/config/vpcs`
- Cluster physical disks v4.3: `/api/clustermgmt/v4.3/config/disks`
