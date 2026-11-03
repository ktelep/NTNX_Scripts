#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Getopt::Long qw(GetOptions);
use NTNX::PC::Client;
use NTNX::PC::Inventory;
use NTNX::PC::Output qw(render_json render_csv);

my %options = (format => 'json', resource => 'vms', limit => 100);
GetOptions(
    'resource=s' => \$options{resource},
    'parent-id=s' => \$options{parent_id},
    'format=s'   => \$options{format},
    'filter=s'   => \$options{filter},
    'select=s'   => \$options{select},
    'limit=i'    => \$options{limit},
    'insecure'   => \$options{insecure},
    'help'       => \$options{help},
) or usage(2);
usage(0) if $options{help};
usage(2) unless $options{format} =~ /\A(?:json|csv)\z/;

my $client = client_from_environment($options{insecure});
my %query;
$query{'$filter'} = $options{filter} if defined $options{filter};
$query{'$select'} = $options{select} if defined $options{select};

if ($options{resource} eq 'volume_group_disks' && !defined $options{parent_id}) {
    die "--parent-id (volume group external ID) is required for volume_group_disks.\n";
}
if ($options{resource} ne 'volume_group_disks' && defined $options{parent_id}) {
    die "--parent-id is only used with volume_group_disks.\n";
}

my $items = NTNX::PC::Inventory->collect($client, $options{resource},
    limit => $options{limit}, query => \%query,
    (defined $options{parent_id} ? (parent_id => $options{parent_id}) : ()),
);
if ($options{format} eq 'csv') {
    binmode STDOUT, ':encoding(UTF-8)';
    print render_csv($items);
} else {
    print render_json($items);
}

sub client_from_environment {
    my ($insecure) = @_;
    my $url = $ENV{NTNX_PC_URL} // die "Set NTNX_PC_URL (for example https://prism-central.example:9440).\n";
    my $username = $ENV{NTNX_PC_USERNAME} // die "Set NTNX_PC_USERNAME.\n";
    my $password = $ENV{NTNX_PC_PASSWORD} // die "Set NTNX_PC_PASSWORD.\n";
    return NTNX::PC::Client->new(
        base_url => $url,
        username => $username,
        password => $password,
        verify_ssl => !$insecure,
        (defined $ENV{NTNX_PC_CA_FILE} ? (ca_file => $ENV{NTNX_PC_CA_FILE}) : ()),
    );
}

sub usage {
    my ($exit) = @_;
    print STDERR <<'USAGE';
Usage: inventory.pl --resource vms|volume_groups|volume_group_disks|subnets|vpcs|physical_disks
                    [--format json|csv] [--filter ODATA] [--select FIELDS]
                    [--limit 1..100] [--parent-id VG_UUID] [--insecure]

Environment: NTNX_PC_URL, NTNX_PC_USERNAME, NTNX_PC_PASSWORD
             Optional NTNX_PC_CA_FILE for a private CA certificate.
              --insecure disables TLS certificate verification.
USAGE
    exit $exit;
}
