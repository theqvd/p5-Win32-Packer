package Win32::Packer::Helpers;

use 5.010;
use strict;
use warnings;
use Carp;
use Path::Tiny;

use Exporter qw(import);
our @EXPORT_OK = grep { no strict 'refs'; defined *{$_}{CODE} } keys %{Win32::Packer::Helpers::};

use Data::Dumper; warn Dumper(\@EXPORT_OK);

sub assert_file { $_[0]->is_file or croak "$_[0] is not a file" }
sub assert_file_name { $_[0] =~ tr{<>:"/\\|?*}{} and croak "$_[0] is not a valid Windows file name" }
sub assert_dir  { $_[0]->is_dir or croak "$_[0] is not a directory" }

sub assert_aoh_path_file { $_->{path}->is_file or croak "$_ is not a file" for @{$_[0]} }
sub assert_aoh_path_dir { $_->{path}->is_dir or croak "$_ is not a directory" for @{$_[0]} }

sub assert_subsystem {
    $_[0] =~ /^(?:windows|console)$/
        or croak "app_subsystem must be 'windows' or 'console'";
}

sub mkpath {
    my $p = path(shift);
    $p->mkpath;
    $p
}

sub to_bool { $_[0] ? 1 : 0 }
sub to_list {
    return @{$_[0]} if ref $_[0] eq 'ARRAY';
    return $_[0] if defined $_[0];
    ()
}

sub to_array { [to_list(shift)] }

sub to_array_path { [map path($_), to_list(shift)] }

sub to_loh_path {
    map {
        my %h = (ref eq 'HASH' ? %$_ : (path => $_));
        defined and $_ = path($_) for @h{qw(path subdir icon)};
        $_ = to_array_path($_) for @h{qw(search_path)};
        $h{basename} //= $h{path}->basename(qw/\.\w*/);
        assert_subsystem($h{subsystem}) if defined $h{subsystem};
        \%h
    } to_list(shift)
}

sub to_aoh_path { [ to_loh_path(shift) ] } 

sub windows_directory {
    require Win32::API;
    state $fn = Win32::API->new("KERNEL32","GetWindowsDirectoryA","PN","N");
    my $buffer = "\0" x 255;
    $fn->Call($buffer, length $buffer);
    $buffer =~ tr/\0//d;
    path($buffer)->realpath;
}

sub c_string_quote {
    my $str = shift;
    $str =~ s/(["\\])/\\$1/g;
    qq("$str")
}

1;
