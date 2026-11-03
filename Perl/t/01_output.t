use strict;
use warnings;

use Test::More;
use JSON::PP qw(decode_json);
use lib 'lib';
use NTNX::PC::Output qw(render_json render_csv flatten_record encode_path_component);

my $records = [
    { name => 'app,one', memorySizeBytes => 1024, nics => [{ mac => '00:11' }] },
    { name => "line\nbreak", powerState => 'ON', nics => [] },
];

is_deeply(decode_json(render_json($records)), $records, 'JSON output round-trips nested data');
my $csv = render_csv($records);
like($csv, qr/memorySizeBytes,name,nics,powerState/, 'CSV has stable sorted field columns');
like($csv, qr/"app,one"/, 'CSV quotes commas');
like($csv, qr/"line\nbreak"/, 'CSV quotes line breaks');
like($csv, qr/00:11/, 'nested arrays are encoded as JSON text');
is(flatten_record({ nic => { mac => '00:11' } })->{'nic.mac'}, '00:11', 'nested hashes use dotted column names');
is(encode_path_component('name with space'), 'name%20with%20space', 'path components are escaped');

done_testing;
