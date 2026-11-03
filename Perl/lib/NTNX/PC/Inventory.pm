package NTNX::PC::Inventory;

use strict;
use warnings;

use NTNX::PC::Output qw(encode_path_component);

my %RESOURCE = (
    vms => {
        path => '/api/vmm/v4.3/ahv/config/vms',
        description => 'AHV virtual machines',
    },
    volume_groups => {
        path => '/api/volumes/v4.3/config/volume-groups',
        description => 'Volume groups',
    },
    volume_group_disks => {
        path => '/api/volumes/v4.3/config/volume-groups/{parent_id}/disks',
        description => 'Disks attached to a volume group',
        parent_required => 1,
    },
    subnets => {
        path => '/api/networking/v4.4/config/subnets',
        description => 'Networking subnets',
    },
    vpcs => {
        path => '/api/networking/v4.4/config/vpcs',
        description => 'Networking VPCs',
    },
    physical_disks => {
        path => '/api/clustermgmt/v4.3/config/disks',
        description => 'Physical cluster disks',
    },
);

sub resources { return \%RESOURCE }

sub collect {
    my ($class, $client, $resource, %args) = @_;
    die "Unknown inventory resource '$resource'.\n" unless exists $RESOURCE{$resource};
    my $path = $RESOURCE{$resource}{path};
    if ($RESOURCE{$resource}{parent_required}) {
        die "A parent_id is required for '$resource'.\n" unless defined $args{parent_id};
        $path =~ s/\{parent_id\}/encode_path_component($args{parent_id})/e;
        delete $args{parent_id};
    }
    return $client->get_collection($path, %args);
}

1;
