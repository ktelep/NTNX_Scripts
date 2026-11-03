#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Getopt::Long qw(GetOptions);
use JSON::PP qw(decode_json);
use NTNX::PC::AHV;
use NTNX::PC::Client;
use NTNX::PC::Output qw(render_json);

my %options;
GetOptions(
    'action=s'    => \$options{action},
    'vm-id=s'     => \$options{vm_id},
    'id=s'        => \$options{id},
    'body-json=s' => \$options{body_json},
    'confirm'     => \$options{confirm},
    'insecure'    => \$options{insecure},
    'help'        => \$options{help},
) or usage(2);
usage(0) if $options{help};
usage(2) unless $options{action} && $options{action} =~ /\A(?:get|create|update|delete)\z/;
usage(2) unless $options{vm_id};
usage(2) if $options{action} =~ /\A(?:get|update|delete)\z/ && !$options{id};
usage(2) if $options{action} =~ /\A(?:create|update)\z/ && !$options{body_json};
die "Refusing to mutate without --confirm.\n" if $options{action} =~ /\A(?:create|update|delete)\z/ && !$options{confirm};

my $client = client_from_environment($options{insecure});
my $ahv = NTNX::PC::AHV->new(client => $client);
my $response;
if ($options{action} eq 'get') {
    $response = $ahv->get_nic($options{vm_id}, $options{id});
} elsif ($options{action} eq 'create') {
    $response = $ahv->create_nic($options{vm_id}, read_json_file($options{body_json}));
} elsif ($options{action} eq 'update') {
    $response = $ahv->update_nic($options{vm_id}, $options{id}, read_json_file($options{body_json}));
} else {
    $response = $ahv->delete_nic($options{vm_id}, $options{id});
}

print render_json({
    status => $response->{status},
    etag   => NTNX::PC::Client::response_etag($response),
    body   => $response->{body},
});

sub client_from_environment {
    my ($insecure) = @_;
    for my $key (qw(NTNX_PC_URL NTNX_PC_USERNAME NTNX_PC_PASSWORD)) {
        die "Set $key in the environment.\n" unless defined $ENV{$key};
    }
    return NTNX::PC::Client->new(
        base_url => $ENV{NTNX_PC_URL}, username => $ENV{NTNX_PC_USERNAME}, password => $ENV{NTNX_PC_PASSWORD},
        verify_ssl => !$insecure,
        (defined $ENV{NTNX_PC_CA_FILE} ? (ca_file => $ENV{NTNX_PC_CA_FILE}) : ()),
    );
}

sub read_json_file {
    my ($file) = @_;
    open my $fh, '<:encoding(UTF-8)', $file or die "Cannot open JSON file '$file': $!\n";
    local $/;
    my $json = <$fh>;
    close $fh;
    my $value = eval { decode_json($json) };
    die "Invalid JSON in '$file': $@" if $@;
    die "JSON file '$file' must contain an object.\n" unless ref($value) eq 'HASH';
    return $value;
}

sub usage {
    my ($exit) = @_;
    print STDERR <<'USAGE';
Usage:
  nic_crud.pl --action get --vm-id VM_UUID --id NIC_UUID
  nic_crud.pl --action create --vm-id VM_UUID --body-json create-nic.json --confirm
  nic_crud.pl --action update --vm-id VM_UUID --id NIC_UUID --body-json nic-changes.json --confirm
  nic_crud.pl --action delete --vm-id VM_UUID --id NIC_UUID --confirm
  Add --insecure to any command to bypass TLS certificate verification.

NIC updates fetch the full current representation and use If-Match. Mutating
actions require --confirm. Credentials are environment-based.
USAGE
    exit $exit;
}
