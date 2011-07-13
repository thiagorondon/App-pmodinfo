
package App::pmodinfo;

use strict;
use warnings;
use Getopt::Long ();
use File::stat;
use DateTime;

our $VERSION = '0.01';

sub new {
    my $class = shift;

    bless {
        author   => undef,
        full     => undef,
        filename => 0,
        pod      => 0,
        @_
    }, $class;
}

sub parse_options {
    my $self = shift;

    Getopt::Long::Configure("bundling");
    Getopt::Long::GetOptions(
        'a|author!'   => sub { $self->{author}   = 1 },
        'f|filename!' => sub { $self->{filename} = 1 },
        'p|pod!'      => sub { $self->{pod}      = 1 },
        'f|full!' =>
          sub { $self->{author} = $self->{filename} = $self->{pod} = 1 },
    );

    $self->{argv} = \@ARGV;
}

sub show_help {
    my $self = shift;

    if ( $_[0] ) {
        die <<USAGE;
Usage: pmodinfo Module [...]

Try `pmodinfo --help` for more options.
USAGE
    }

    print <<HELP;
Usage: pmodinfo Module [...]

Options:
    -a,--author
    -f,--filename
    -p,--pod
    -f,--full
HELP

    return 1;
}

sub print_block {
    my $self = shift;
    my ( $description, $data, $check ) = @_;
    print " $description: $data\n" if $check;
}

sub format_date {
    my ( $self, $epoch ) = @_;
    my $dt = DateTime->from_epoch( epoch => $epoch );
    return join( ' ', $dt->ymd, $dt->hms );
}

sub run {
    my $self = shift;

    $self->show_help unless @{ $self->{argv} };

    for my $module ( @{ $self->{argv} } ) {
        my ( $install, $meta, $deprecated ) = $self->check_module( $module, 0 );

        print "$module not found" and next unless $install;

        print "$module is installed with version " . $meta->version || undef;
        print "(deprecated)" if defined($deprecated);
        print ".\n";

        my $ctime = $self->format_date( ( stat $meta->filename )[10] );
        $self->print_block( 'filename   ', $meta->filename, $self->{filename} );
        $self->print_block( '  ctime    ', $ctime,          $self->{filename} );
        $self->print_block( 'POD content',
            ( $meta->contains_pod ? 'yes' : 'no' ),
            $self->{pod} );
    }
}

# check_module from cpanminus.
sub check_module {
    my ( $self, $mod, $want_ver ) = @_;

    my $meta = do {
        no strict 'refs';
        local ${"$mod\::VERSION"};
        require Module::Metadata;
        Module::Metadata->new_from_module( $mod, inc => $self->{search_inc} );
      }
      or return 0, undef;

    my $version = $meta->version;

    # When -L is in use, the version loaded from 'perl' library path
    # might be newer than the version that is shipped with the current perl
    if ( $self->{self_contained} && $self->loaded_from_perl_lib($meta) ) {
        my $core_version = eval {
            require Module::CoreList;
            $Module::CoreList::version{ $] + 0 }{$mod};
        };

        # HACK: Module::Build 0.3622 or later has non-core module
        # dependencies such as Perl::OSType and CPAN::Meta, and causes
        # issues when a newer version is loaded from 'perl' while deps
        # are loaded from the 'site' library path. Just assume it's
        # not in the core, and install to the new local library path.
        # Core version 0.38 means >= perl 5.14 and all deps are satisfied
        if ( $mod eq 'Module::Build' ) {
            if (
                $version < 0.36 or    # too old anyway
                ( $core_version != $version and $core_version < 0.38 )
              )
            {
                return 0, undef;
            }
        }

        $version = $core_version if %Module::CoreList::version;
    }

    $self->{local_versions}{$mod} = $version;

    if ( $self->is_deprecated($meta) ) {
        return 0, $meta, 1;
    }
    elsif ( !$want_ver or $version >= version->new($want_ver) ) {
        return 1, $meta;
    }
    else {
        return 0, $version;
    }
}

sub is_deprecated {
    my ( $self, $meta ) = @_;

    my $deprecated = eval {
        require Module::CoreList;
        Module::CoreList::is_deprecated( $meta->{module} );
    };

    return unless $deprecated;
    return $self->loaded_from_perl_lib($meta);
}

1;

