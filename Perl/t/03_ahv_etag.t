use strict;
use warnings;

use Test::More;
use JSON::PP qw(encode_json decode_json);
use lib 'lib';
use NTNX::PC::AHV;
use NTNX::PC::Client;

{
    package Local::QueueUA;
    sub new { bless { replies => $_[1] || [], calls => [] }, $_[0] }
    sub request {
        my ($self, $method, $url, $options) = @_;
        push @{$self->{calls}}, { method => $method, url => $url, options => $options };
        my $reply = shift @{$self->{replies}} or die 'No mock HTTP response queued';
        return $reply;
    }
}

my $vm = {
    extId => 'vm-id', _etag => 'old-body-tag', links => [{ href => '/ignore' }],
    name => 'old-name', disks => [{ extId => 'disk-id', backingInfo => { diskSizeBytes => 1024 } }],
    nics => [{ extId => 'nic-id', nicNetworkInfo => { subnet => { extId => 'subnet-id' } } }],
};
my $ua = Local::QueueUA->new([
    { success => 1, status => 200, headers => { etag => 'vm-tag-1' }, content => encode_json({ data => $vm }) },
    { success => 1, status => 200, headers => {}, content => encode_json({ data => { taskId => 't1' } }) },
    { success => 1, status => 200, headers => { ETag => 'nic-tag-1' }, content => encode_json({ data => { extId => 'nic-id', _etag => 'old', links => [], nicBackingInfo => { model => 'VIRTIO' } } }) },
    { success => 1, status => 200, headers => {}, content => encode_json({ data => { taskId => 't2' } }) },
    { success => 1, status => 202, headers => {}, content => encode_json({ data => { taskId => 't3' } }) },
]);
my $client = NTNX::PC::Client->new(
    base_url => 'https://pc.example:9440', username => 'demo', password => 'secret', ua => $ua,
);
my $ahv = NTNX::PC::AHV->new(client => $client);

$ahv->update_vm('vm-id', { name => 'new-name' });
is($ua->{calls}[1]{options}{headers}{'If-Match'}, 'vm-tag-1', 'VM PUT uses ETag from preceding GET');
my $vm_body = decode_json($ua->{calls}[1]{options}{content});
is($vm_body->{name}, 'new-name', 'VM update applies requested change');
is_deeply($vm_body->{disks}, $vm->{disks}, 'VM update preserves complete disk configuration');
is_deeply($vm_body->{nics}, $vm->{nics}, 'VM update preserves complete NIC configuration');
ok(!exists $vm_body->{_etag} && !exists $vm_body->{links}, 'VM update strips _etag and links');

$ahv->update_nic('vm-id', 'nic-id', { description => 'updated' });
is($ua->{calls}[3]{options}{headers}{'If-Match'}, 'nic-tag-1', 'NIC PUT uses its fetched ETag');
my $nic_body = decode_json($ua->{calls}[3]{options}{content});
is($nic_body->{description}, 'updated', 'NIC update applies requested change');
ok(!exists $nic_body->{_etag} && !exists $nic_body->{links}, 'NIC update strips _etag and links');

$ahv->delete_vm('vm-id');
ok(!exists $ua->{calls}[4]{options}{headers}{'If-Match'}, 'VM DELETE does not send If-Match per schema');

my $missing_etag_ua = Local::QueueUA->new([
    { success => 1, status => 200, headers => {}, content => encode_json({ data => { extId => 'vm-id', name => 'x' } }) },
]);
my $missing_etag = NTNX::PC::AHV->new(client => NTNX::PC::Client->new(
    base_url => 'https://pc.example:9440', username => 'demo', password => 'secret', ua => $missing_etag_ua,
));
eval { $missing_etag->update_vm('vm-id', { name => 'changed' }) };
like($@, qr/did not include an ETag/, 'update refuses to run without a concurrency token');
is(scalar @{$missing_etag_ua->{calls}}, 1, 'no PUT is sent if ETag is missing');

done_testing;
