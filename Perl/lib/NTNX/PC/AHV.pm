package NTNX::PC::AHV;

use strict;
use warnings;

use NTNX::PC::Client ();
use NTNX::PC::Output qw(encode_path_component);
use JSON::PP qw(decode_json encode_json);

my $VM_COLLECTION = '/api/vmm/v4.3/ahv/config/vms';

sub new {
    my ($class, %args) = @_;
    die "A client is required.\n" unless $args{client};
    return bless { client => $args{client} }, $class;
}

sub list_vms {
    my ($self, %args) = @_;
    return $self->{client}->get_collection($VM_COLLECTION, %args);
}

sub get_vm {
    my ($self, $vm_id) = @_;
    my $path = $VM_COLLECTION . '/' . encode_path_component($vm_id);
    return $self->{client}->request('GET', $path);
}

sub create_vm {
    my ($self, $body) = @_;
    die "VM create body must be a hash reference.\n" unless ref($body) eq 'HASH';
    return $self->{client}->request('POST', $VM_COLLECTION, body => $body);
}

sub update_vm {
    my ($self, $vm_id, $changes) = @_;
    die "VM update changes must be a hash reference.\n" unless ref($changes) eq 'HASH';
    my $current = $self->get_vm($vm_id);
    my $etag = NTNX::PC::Client::response_etag($current);
    die "GET VM response did not include an ETag; refusing conditional update.\n" unless defined $etag && length $etag;
    my $resource = NTNX::PC::Client::response_data($current);
    die "GET VM response did not contain a data object.\n" unless ref($resource) eq 'HASH';
    my $body = decode_json(encode_json($resource));
    delete @{$body}{qw(_etag links)};
    $body->{$_} = $changes->{$_} for keys %$changes;
    return $self->{client}->request('PUT', $VM_COLLECTION . '/' . encode_path_component($vm_id),
        body => $body, if_match => $etag);
}

sub delete_vm {
    my ($self, $vm_id) = @_;
    return $self->{client}->request('DELETE', $VM_COLLECTION . '/' . encode_path_component($vm_id));
}

sub get_nic {
    my ($self, $vm_id, $nic_id) = @_;
    return $self->{client}->request('GET', _nic_path($vm_id, $nic_id));
}

sub create_nic {
    my ($self, $vm_id, $body) = @_;
    die "NIC create body must be a hash reference.\n" unless ref($body) eq 'HASH';
    my $path = $VM_COLLECTION . '/' . encode_path_component($vm_id) . '/nics';
    return $self->{client}->request('POST', $path, body => $body);
}

sub update_nic {
    my ($self, $vm_id, $nic_id, $changes) = @_;
    die "NIC update changes must be a hash reference.\n" unless ref($changes) eq 'HASH';
    my $current = $self->get_nic($vm_id, $nic_id);
    my $etag = NTNX::PC::Client::response_etag($current);
    die "GET NIC response did not include an ETag; refusing conditional update.\n" unless defined $etag && length $etag;
    my $resource = NTNX::PC::Client::response_data($current);
    die "GET NIC response did not contain a data object.\n" unless ref($resource) eq 'HASH';
    my $body = decode_json(encode_json($resource));
    delete @{$body}{qw(_etag links)};
    $body->{$_} = $changes->{$_} for keys %$changes;
    return $self->{client}->request('PUT', _nic_path($vm_id, $nic_id),
        body => $body, if_match => $etag);
}

sub delete_nic {
    my ($self, $vm_id, $nic_id) = @_;
    return $self->{client}->request('DELETE', _nic_path($vm_id, $nic_id));
}

sub _nic_path {
    my ($vm_id, $nic_id) = @_;
    return $VM_COLLECTION . '/' . encode_path_component($vm_id)
        . '/nics/' . encode_path_component($nic_id);
}

1;
