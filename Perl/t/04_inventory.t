use strict;
use warnings;

use Test::More;
use JSON::PP qw(encode_json);
use lib 'lib';
use NTNX::PC::Client;
use NTNX::PC::Inventory;

{
    package Local::InventoryUA;
    sub new { bless { calls => [] }, $_[0] }
    sub request {
        my ($self, $method, $url, $options) = @_;
        push @{$self->{calls}}, { method => $method, url => $url, options => $options };
        return { success => 1, status => 200, headers => {}, content => JSON::PP::encode_json({ data => [] }) };
    }
}

my $ua = Local::InventoryUA->new;
my $client = NTNX::PC::Client->new(
    base_url => 'https://pc.example:9440', username => 'demo', password => 'secret', ua => $ua,
);
NTNX::PC::Inventory->collect($client, 'volume_group_disks', parent_id => 'vg id', limit => 20);
like($ua->{calls}[0]{url}, qr{/api/volumes/v4\.3/config/volume-groups/vg%20id/disks},
    'volume group disk route scopes by URL-encoded volume group ID');
like($ua->{calls}[0]{url}, qr/\$limit=20/, 'resource collection uses requested limit');

eval { NTNX::PC::Inventory->collect($client, 'volume_group_disks') };
like($@, qr/parent_id is required/, 'volume group disk route requires a parent ID');
eval { NTNX::PC::Inventory->collect($client, 'not-a-resource') };
like($@, qr/Unknown inventory resource/, 'unknown inventory resources are rejected');

done_testing;
