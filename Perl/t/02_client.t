use strict;
use warnings;

use Test::More;
use JSON::PP qw(encode_json);
use lib 'lib';
use NTNX::PC::Client;

my $secure_client = NTNX::PC::Client->new(
    base_url => 'https://pc.example:9440', username => 'demo', password => 'secret',
);
ok($secure_client->{ua}{verify_SSL}, 'TLS certificate verification is on by default');
my $insecure_client = NTNX::PC::Client->new(
    base_url => 'https://pc.example:9440', username => 'demo', password => 'secret', verify_ssl => 0,
);
ok(!$insecure_client->{ua}{verify_SSL}, 'TLS certificate verification can be explicitly disabled');

{
    package Local::FakeUA;
    sub new { bless { replies => $_[1] || [], calls => [] }, $_[0] }
    sub request {
        my ($self, $method, $url, $options) = @_;
        push @{$self->{calls}}, { method => $method, url => $url, options => $options };
        my $reply = shift @{$self->{replies}} or die 'No mock HTTP response queued';
        return $reply;
    }
}

my $ua = Local::FakeUA->new([
    { success => 1, status => 200, headers => {}, content => encode_json({ data => [{ id => 1 }, { id => 2 }] }) },
    { success => 1, status => 200, headers => {}, content => encode_json({ data => [{ id => 3 }] }) },
]);
my $client = NTNX::PC::Client->new(
    base_url => 'https://pc.example:9440/', username => 'demo', password => 'secret', ua => $ua,
);
my $items = $client->get_collection('/api/vmm/v4.3/ahv/config/vms',
    limit => 2, query => { '$filter' => "name eq 'web app'" });
is_deeply($items, [{ id => 1 }, { id => 2 }, { id => 3 }], 'collection pages are combined');
is(scalar @{$ua->{calls}}, 2, 'fetch stops on the short page');
like($ua->{calls}[0]{url}, qr/\$filter=name%20eq%20%27web%20app%27/, 'OData query value is URL encoded');
like($ua->{calls}[0]{url}, qr/\$page=0/, 'first page starts at zero');
like($ua->{calls}[1]{url}, qr/\$page=1/, 'next page increments');
like($ua->{calls}[0]{options}{headers}{Authorization}, qr/^Basic /, 'Basic authorization header is set');

my $empty_ua = Local::FakeUA->new([
    { success => 1, status => 200, headers => {}, content => encode_json({ metadata => { totalAvailableResults => 0 } }) },
]);
my $empty_client = NTNX::PC::Client->new(
    base_url => 'https://pc.example:9440', username => 'demo', password => 'secret', ua => $empty_ua,
);
is_deeply($empty_client->get_collection('/api/vmm/v4.3/ahv/config/vms'), [],
    'an empty API collection may omit data when metadata reports zero results');

my $etag = NTNX::PC::Client::response_etag({ headers => { eTaG => 'header-tag' }, body => {} });
is($etag, 'header-tag', 'ETag response header is read case-insensitively');
is(NTNX::PC::Client::response_etag({ headers => {}, body => { data => { _etag => 'body-tag' } } }),
    'body-tag', 'body _etag is supported as a fallback');

my $bad = Local::FakeUA->new([
    { success => 0, status => 412, headers => {}, content => encode_json({ message => 'stale ETag' }) },
]);
my $bad_client = NTNX::PC::Client->new(
    base_url => 'https://pc.example:9440', username => 'demo', password => 'secret', ua => $bad,
);
eval { $bad_client->request('PUT', '/api/vmm/v4.3/ahv/config/vms/id', body => { name => 'x' }, if_match => 'stale') };
like($@, qr/HTTP 412.*stale ETag/, 'HTTP concurrency errors include API message');
like($bad->{calls}[0]{options}{headers}{'If-Match'}, qr/^stale$/, 'conditional request sends If-Match');
like($bad->{calls}[0]{options}{headers}{'NTNX-Request-Id'}, qr/^[0-9a-f-]{36}$/, 'write request gets UUID request ID');

my $transport = Local::FakeUA->new([
    { success => 0, status => 599, headers => {}, content => 'SSL connection failed: certificate check failed' },
]);
my $transport_client = NTNX::PC::Client->new(
    base_url => 'https://pc.example:9440', username => 'demo', password => 'secret', ua => $transport,
);
eval { $transport_client->request('GET', '/api/vmm/v4.3/ahv/config/vms') };
like($@, qr/HTTP 599.*SSL connection failed/, 'transport errors preserve useful non-JSON details');

my $task_ua = Local::FakeUA->new([
    { success => 1, status => 200, headers => {}, content => encode_json({ data => { status => 'RUNNING' } }) },
    { success => 1, status => 200, headers => {}, content => encode_json({ data => { status => 'SUCCEEDED' } }) },
]);
my $task_client = NTNX::PC::Client->new(
    base_url => 'https://pc.example:9440', username => 'demo', password => 'secret', ua => $task_ua,
);
my $task = $task_client->wait_for_task('task-id', attempts => 2, interval => 0, sleep => sub { });
is($task->{status}, 'SUCCEEDED', 'task polling returns the terminal status');
like($task_ua->{calls}[0]{url}, qr{/api/prism/v4\.4/config/tasks/task-id$}, 'task polling uses Prism tasks endpoint');

done_testing;
