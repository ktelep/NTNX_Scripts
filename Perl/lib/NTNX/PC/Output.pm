package NTNX::PC::Output;

use strict;
use warnings;

use Exporter qw(import);
use JSON::PP qw(encode_json);
use Encode qw(encode);

our @EXPORT_OK = qw(render_json render_csv flatten_record encode_path_component);

sub render_json {
    my ($records) = @_;
    return JSON::PP->new->canonical->pretty->utf8->encode($records);
}

sub flatten_record {
    my ($record) = @_;
    my %flat;
    _flatten_into(\%flat, '', $record);
    return \%flat;
}

sub _flatten_into {
    my ($flat, $prefix, $value) = @_;
    if (ref($value) eq 'HASH') {
        for my $key (sort keys %$value) {
            my $path = length $prefix ? "$prefix.$key" : $key;
            _flatten_into($flat, $path, $value->{$key});
        }
    } else {
        $flat->{$prefix} = ref($value) ? encode_json($value) : (defined $value ? "$value" : '');
    }
}

sub render_csv {
    my ($records) = @_;
    die "CSV output expects an array reference.\n" unless ref($records) eq 'ARRAY';
    my @rows = map { flatten_record($_) } @$records;
    my %seen;
    my @columns;
    for my $row (@rows) {
        for my $key (sort keys %$row) {
            push @columns, $key unless $seen{$key}++;
        }
    }
    @columns = sort @columns;
    return "\n" unless @columns;
    my @lines;
    push @lines, join(',', map { _csv_quote($_) } @columns);
    for my $row (@rows) {
        push @lines, join(',', map { _csv_quote($row->{$_} // '') } @columns);
    }
    return join("\r\n", @lines) . "\r\n";
}

sub encode_path_component {
    my ($value) = @_;
    die "Path component is required.\n" unless defined $value;
    my $bytes = encode('UTF-8', "$value");
    $bytes =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
    return $bytes;
}

sub _csv_quote {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/"/""/g;
    return $value =~ /[",\r\n]/ ? "\"$value\"" : $value;
}

1;
