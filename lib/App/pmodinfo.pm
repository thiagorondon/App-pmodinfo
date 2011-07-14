
package App::pmodinfo;

use strict;
use warnings;
use Getopt::Long ();
use File::stat;
use DateTime;
use Config;
use Parse::CPAN::Meta;
use LWP::Simple;

# VERSION

sub new {
    my $class = shift;

    bless {
        author => undef,
        full   => undef,
        hash   => undef,
        @_
    }, $class;
}

sub parse_options {
    my $self = shift;

    Getopt::Long::Configure("bundling");
    Getopt::Long::GetOptions(
        'v|version!' => sub { $self->show_version },
        'f|full!'    => sub { $self->{full} = 1 },
        'h|hash!'    => sub { $self->{hash} = 1 },
        'c|cpan!'    => sub { $self->{cpan} = 1 },
    );

    $self->{argv} = \@ARGV;
}

sub show_version {
    my $self = shift;
    no strict;    # Dist::Zilla, VERSION.
    print "pmodinfo version $VERSION\n";
    exit 1;
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
    -c,--cpan
    -f,--full
    -v,--version
    -h,--hash
HELP

    return 1;
}

sub print_block {
    my $self = shift;
    my ( $description, $data, @check ) = @_;
    map { print "  $description: $data\n" if $_ } @check;
}

sub format_date {
    my ( $self, $epoch ) = @_;
    return '' unless $epoch;
    my $dt = DateTime->from_epoch( epoch => $epoch );
    return join( ' ', $dt->ymd, $dt->hms );
}

sub run {
    my $self = shift;

    $self->show_help unless @{ $self->{argv} };

    print "{\n" if $self->{hash};

    for my $module ( @{ $self->{argv} } ) {
        $self->{hash}
            ? $self->show_modules_hash($module)
            : $self->show_modules($module);

    }

    print "};\n" if $self->{hash};
}

sub show_modules_hash {
    my ( $self, $module ) = @_;
    my ( $install, $meta ) = $self->check_module( $module, 0 );
    my $version = $meta->version;
    print "\t'$module' => $version,\n" if $install;
}

sub cpanpage {
    my ( $self, $module ) = @_;
    $module =~ s/::/-/g;
    return "http://search.cpan.org/dist/$module";
}

sub show_modules {
    my ( $self, $module ) = @_;
    my ( $install, $meta, $deprecated ) = $self->check_module( $module, 0 );

    print "$module not found" and next unless $install;

    print "$module version is " . $meta->version || undef;
    print "(deprecated)" if defined($deprecated);
    print ".\n";

    my $stat  = stat $meta->filename;
    my $ctime = $self->format_date( $stat->[10] );
    $self->print_block( 'cpan page  ', $self->cpanpage($module), $self->{full} );
    $self->print_block( 'filename   ', $meta->filename,          $self->{full} );
    $self->print_block( '  ctime    ', $ctime,                   $self->{full} );
    $self->print_block(
        'POD content',
        (   $meta->contains_pod
            ? 'yes'
            : 'no'
        ),
        $self->{full}
    );

    if ( $self->{full} or $self->{cpan} ) {
        my $cpan_version = $self->get_last_version_from_cpan($module);
        $self->print_block( 'Last cpan version', $cpan_version, 1 );
    }
}

sub parse_meta_string {
    my ( $self, $yaml ) = @_;
    return eval { ( Parse::CPAN::Meta::Load($yaml) )[0] } || undef;
}

sub get_last_version_from_cpan {
    my ( $self, $module ) = @_;
    $module =~ s/::/-/g;
    my $meta_yml = get("http://search.cpan.org/meta/$module/META.yml");
    my $meta     = $self->parse_meta_string($meta_yml);
    return $meta->{version};
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
            if ($version < 0.36 or    # too old anyway
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

sub loaded_from_perl_lib {
    my ( $self, $meta ) = @_;

    require Config;
    for my $dir (qw(archlibexp privlibexp)) {
        my $confdir = $Config{$dir};
        if ( $confdir eq substr( $meta->filename, 0, length($confdir) ) ) {
            return 1;
        }
    }

    return;
}

1;
__END__

# ABSTRACT: Perl module info command line.

=head1 SYNOPSIS

    $ pmodinfo Scalar::Util strict
    Scalar::Util version is 1.23.
    strict is installed with version 1.04.

    $ pmodinfo --full Redis::Dump
    Redis::Dump is installed with version 0.013.
    cpan page  : http://search.cpan.org/dist/Redis-Dump
    filename   : /Users/thiago/perl5/perlbrew/perls/perl-5.14.0/lib/site_perl/5.14.0/Redis/Dump.pm
      ctime    : 2011-07-05 19:56:54
    POD content: yes
    Last cpan version: 0.013

    $ pmodinfo --hash Catalyst::Runtime DBIx::Class Data::Printer
    {
        'Catalyst::Runtime' => 5.80032,
        'DBIx::Class' => 0.08192,
        'Data::Printer' => 0.21,
    };

=head1 DESCRIPTION

pmodinfo extracts information from the perl modules given the command
line.

I don't want to use more "perl -MModule\ 999".

=head1 OPTIONS

    -v --version

    -f --full

    -h --hash

=head1 SEE ALSO

L<Module::Metadata>, L<Getopt::Long>

=head1 ACKNOWLEDGE

L<cpanminus>, for the check_module function. :-)


