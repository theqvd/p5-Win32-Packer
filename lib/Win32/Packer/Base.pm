package Win32::Packer::Base;

use Log::Any;
use Path::Tiny;
use Win32::Packer::Helpers qw(assert_dir assert_file assert_file_name mkpath guid);
use Carp;

use Moo;
use namespace::autoclean;

has log             => ( is => 'rw', default => sub { Log::Any->get_logger } );
has work_dir        => ( is => 'lazy', coerce => \&mkpath, isa => \&assert_dir );
has output_dir      => ( is => 'ro', coerce => \&mkpath, isa => \&assert_dir,
                         default => sub { path('.')->realpath } );
has app_name        => ( is => 'ro', default => sub { 'PerlApp' },
                         isa => \&assert_file_name );
has app_version     => ( is => 'ro', isa => \&assert_file_name);

has app_vendor      => ( is => 'ro', default => 'Acme Ltd.');

has app_id          => ( is => 'lazy', default => \&guid );

has app_description => ( is => 'ro' );

has app_keywords    => ( is => 'ro' );

has app_comments    => ( is => 'ro' );

has icon            => ( is => 'ro', isa => \&assert_file, coerce => \&path );

sub _die { croak shift->log->fatal(@_) }

sub _dief { croak shift->log->fatalf(@_) }

1;
