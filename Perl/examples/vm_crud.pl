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
    'action=s'     => \$options{action},
    'id=s'         => \$options{id},
    'body-json=s'  => \$options{body_json},
    'name=s'       => \$options{name},
    'confirm'      => \$options{confirm},
    'insecure'     => \$options{insecure},
    'help'         => \$options{help},
) or usage(2);
usage(0) if $options{help};
usage(2) unless $options{action} && $options{action} =~ /\A(?:list|get|create|update|delete)\z/;
usage(2) if $options{action} =~ /\A(?:get|update|delete)\z/ && !$options{id};
usage(2) if $options{action} =~ /\A(?:create|update)\z/ && !$options{body_json} && !defined $options{name};
die "Refusing to mutate without --confirm.\n" if $options{action} =~ /\A(?:create|update|delete)\z/ && !$options{confirm};

my $client = client_from_environment($options{insecure});
my $ahv = NTNX::PC::AHV->new(client => $client);
my $response;
if ($options{action} eq 'list') {
    print render_json($ahv->list_vms());
    exit 0;
} elsif ($options{action} eq 'get') {
    $response = $ahv->get_vm($options{id});
} elsif ($options{action} eq 'create') {
    my $body = read_json_file($options{body_json});
    $response = $ahv->create_vm($body);
} elsif ($options{action} eq 'update') {
    my $changes = $options{body_json} ? read_json_file($options{body_json}) : { name => $options{name} };
    die "Update JSON must contain an object.\n" unless ref($changes) eq 'HASH';
    $changes->{name} = $options{name} if defined $options{name};
    $response = $ahv->update_vm($options{id}, $changes);
} else {
    $response = $ahv->delete_vm($options{id});
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
    die "--body-json file is required.\n" unless defined $file;
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
  vm_crud.pl --action list
  vm_crud.pl --action get --id VM_UUID
  vm_crud.pl --action create --body-json create-vm.json --confirm
  vm_crud.pl --action update --id VM_UUID --name NEW_NAME --confirm
  vm_crud.pl --action update --id VM_UUID --body-json changes.json --confirm
  vm_crud.pl --action delete --id VM_UUID --confirm
  Add --insecure to any command to bypass TLS certificate verification.

The update body is merged into the latest full VM representation and sent with
If-Match. Mutating actions require --confirm. Credentials are environment-based.
USAGE
    exit $exit;
}
