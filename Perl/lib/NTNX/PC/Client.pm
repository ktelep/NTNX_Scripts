package NTNX::PC::Client;

use strict;
use warnings;

use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);
use MIME::Base64 qw(encode_base64);
use NTNX::PC::Output qw(encode_path_component);

sub new {
    my ($class, %args) = @_;
    for my $required (qw(base_url username password)) {
        die "Missing required client option '$required'.\n" unless defined $args{$required};
    }

    my $base_url = $args{base_url};
    $base_url =~ s{/+$}{};
    die "Prism Central URL must use https://.\n" unless $base_url =~ m{\Ahttps://}i;

    my $verify_ssl = exists $args{verify_ssl} ? !!$args{verify_ssl} : 1;
    my $auth = encode_base64("$args{username}:$args{password}", '');
    my $ua = $args{ua} || HTTP::Tiny->new(
        agent       => 'ntnx-pc-perl-examples/1.0',
        timeout     => $args{timeout} // 60,
        verify_SSL  => $verify_ssl,
        SSL_options => $args{ca_file} ? { SSL_ca_file => $args{ca_file} } : {},
    );

    return bless {
        base_url => $base_url,
        auth     => "Basic $auth",
        ua       => $ua,
        verify_ssl => $verify_ssl,
    }, $class;
}

sub request {
    my ($self, $method, $path, %args) = @_;
    $method = uc $method;
    die "Unsupported HTTP method '$method'.\n" unless $method =~ /\A(?:GET|POST|PUT|PATCH|DELETE)\z/;
    die "API path must start with '/api/'.\n" unless defined $path && $path =~ m{\A/api/};

    my %headers = (
        Authorization => $self->{auth},
        Accept        => 'application/json',
    );
    if (defined $args{if_match}) {
        $headers{'If-Match'} = $args{if_match};
    }
    if ($args{request_id}) {
        $headers{'NTNX-Request-Id'} = $args{request_id};
    } elsif ($method ne 'GET') {
        $headers{'NTNX-Request-Id'} = _uuid_v4();
    }

    my $url = $self->{base_url} . $path;
    if ($args{query} && %{$args{query}}) {
        my @pairs;
        for my $key (sort keys %{$args{query}}) {
            next unless defined $args{query}{$key};
            push @pairs, _query_key($key) . '=' . _url_encode($args{query}{$key});
        }
        $url .= (index($url, '?') >= 0 ? '&' : '?') . join('&', @pairs) if @pairs;
    }

    my %request = (headers => \%headers);
    if (exists $args{body}) {
        $headers{'Content-Type'} = 'application/json';
        $request{content} = encode_json($args{body});
    }
    my $response = $self->{ua}->request($method, $url, \%request);
    my $decoded;
    if (defined $response->{content} && length $response->{content}) {
        my $valid_json = eval { $decoded = decode_json($response->{content}); 1 };
        die "Prism Central returned invalid JSON for $method $path: $@"
            if !$valid_json && $response->{success};
    }

    if (!$response->{success}) {
        my $message = _error_message($decoded, $response->{content});
        die "Prism Central $method $path failed (HTTP $response->{status}): $message\n";
    }

    return {
        status  => $response->{status},
        headers => $response->{headers} || {},
        body    => $decoded,
    };
}

sub get_collection {
    my ($self, $path, %args) = @_;
    my $limit = $args{limit} // 100;
    die "Collection limit must be between 1 and 100.\n" unless $limit >= 1 && $limit <= 100;
    my %query = %{$args{query} || {}};
    die "Do not pass '$' pagination options in query; use limit/page options.\n"
        if exists $query{'$page'} || exists $query{'$limit'};

    my @items;
    my $page = $args{page} // 0;
    my $max_pages = $args{max_pages} // 10_000;
    for (my $count = 0; $count < $max_pages; $count++, $page++) {
        my %page_query = (%query, '$page' => $page, '$limit' => $limit);
        my $response = $self->request('GET', $path, query => \%page_query);
        my $data = $response->{body}{data};
        if (!defined $data && ref($response->{body}{metadata}) eq 'HASH'
            && ($response->{body}{metadata}{totalAvailableResults} // 0) == 0) {
            $data = [];
        }
        die "Prism Central collection response has no 'data' array.\n"
            unless ref($data) eq 'ARRAY';
        push @items, @$data;
        last if @$data < $limit;
        die "Exceeded maximum collection pages ($max_pages).\n" if $count == $max_pages - 1;
    }
    return \@items;
}

sub response_data {
    my ($response) = @_;
    return undef unless $response && ref($response->{body}) eq 'HASH';
    return $response->{body}{data};
}

sub response_etag {
    my ($response) = @_;
    return undef unless $response;
    my $headers = $response->{headers} || {};
    for my $name (keys %$headers) {
        return $headers->{$name} if lc($name) eq 'etag' && defined $headers->{$name};
    }
    my $body = $response->{body};
    return unless ref($body) eq 'HASH';
    my $data = $body->{data};
    return $data->{_etag} if ref($data) eq 'HASH' && defined $data->{_etag};
    return $body->{_etag};
}

sub wait_for_task {
    my ($self, $task_id, %args) = @_;
    die "Task ID is required.\n" unless defined $task_id && length $task_id;
    my $attempts = $args{attempts} // 36;
    my $interval = $args{interval} // 5;
    my $sleep = $args{sleep} || sub { sleep $_[0] };
    my $path = '/api/prism/v4.4/config/tasks/' . encode_path_component($task_id);

    for my $attempt (1 .. $attempts) {
        my $response = $self->request('GET', $path);
        my $task = response_data($response);
        die "Task response did not contain a data object.\n" unless ref($task) eq 'HASH';
        return $task if ($task->{status} // '') =~ /\A(?:SUCCEEDED|FAILED|CANCELLED)\z/;
        $sleep->($interval) if $attempt < $attempts;
    }
    die "Task '$task_id' did not complete after $attempts checks.\n";
}

sub _error_message {
    my ($decoded, $raw) = @_;
    if (ref($decoded) eq 'HASH') {
        for my $key (qw(message errorMessage)) {
            return $decoded->{$key} if defined $decoded->{$key} && !ref($decoded->{$key});
        }
        if (ref($decoded->{error}) eq 'HASH' && defined $decoded->{error}{message}) {
            return $decoded->{error}{message};
        }
    }
    return $raw if defined $raw && length $raw;
    return 'No response body';
}

sub _query_key {
    my ($key) = @_;
    # OData option names use a literal dollar prefix in the URL.
    return '$' . _url_encode(substr($key, 1)) if $key =~ /^\$/;
    return _url_encode($key);
}

sub _url_encode {
    my ($value) = @_;
    use Encode qw(encode);
    my $bytes = encode('UTF-8', "$value");
    $bytes =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
    return $bytes;
}

sub _uuid_v4 {
    open my $random, '<:raw', '/dev/urandom' or die "Cannot read /dev/urandom for request ID: $!\n";
    read($random, my $bytes, 16) == 16 or die "Could not read random bytes for request ID.\n";
    close $random;
    my @b = unpack('C*', $bytes);
    $b[6] = ($b[6] & 0x0f) | 0x40;
    $b[8] = ($b[8] & 0x3f) | 0x80;
    return sprintf('%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x', @b);
}

1;
