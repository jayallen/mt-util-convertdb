package MT::ConvertDB::CLI;

use MT::ConvertDB::ToolSet;
use Term::ProgressBar 2.00;
use List::Util qw( reduce );
use MooX::Options;
use vars qw( $l4p );

option old_config => (
    is     => 'ro',
    format => 's',
    doc => '',
    longdoc => '',
    default => './mt-config.cgi',
);

option new_config => (
    is       => 'ro',
    format   => 's',
    required => 1,
    doc => '',
    longdoc => '',
);

option types => (
    is     => 'ro',
    format => 's@',
    autosplit => ',',
    default => sub { [] },
    doc => '',
    longdoc => '',
);

option save => (
    is => 'ro',
    doc => '',
    longdoc => '',
    default => 0,
);

option init_only => (
    is => 'ro',
    doc => '',
    longdoc => '',
);

has classmgr => (
    is => 'lazy',
);

has cfgmgr => (
    is => 'lazy',
);

has class_objects => (
    is => 'lazy',
);

sub _build_cfgmgr {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    my %param = (
        read_only => ($self->save ? 0 : 1),
        new       => $self->new_config,
        old       => $self->old_config,
    );
    use_module('MT::ConvertDB::ConfigMgr')->new(%param);
}

sub _build_classmgr { use_module('MT::ConvertDB::ClassMgr')->new() }

sub _build_class_objects {
    my $self = shift;
    $self->classmgr->class_objects($self->types);
}

sub run {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $classmgr   = $self->classmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

    if ( $self->init_only ) {
        $l4p->info('Initialization done.  Exiting due to --init-only');
        exit;
    }

    $self->migrate();
}

sub migrate {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $classmgr   = $self->classmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

    my $count       = 0;
    my $next_update = 0;
    my $max         = reduce { $a + $b }
                         map { $_->object_count + $_->meta_count } @$class_objs;
    print "MAX: $max\n";
    my $progress = Term::ProgressBar->new({
        name => 'Migrated', count => $max, remove => 0
    });
    $progress->minor(0);

    try {
        local $SIG{__WARN__} = sub { $l4p->warn($_[0]) };

        ###
        ### First pass to load/save objects
        ###
        foreach my $classobj ( @$class_objs ) {
            my $class = $classobj->class;
            $cfgmgr->newdb->remove_all( $classobj );

            my $iter = $cfgmgr->olddb->load_iter( $classobj );
            ###l4p $l4p->info($classobj->class.' object migration starting');
            while (my $obj = $iter->()) {
                my $meta = $cfgmgr->olddb->load_meta( $classobj, $obj );
                $cfgmgr->newdb->save( $classobj, $obj, $meta );

                $count += scalar(keys %$meta) + 1;
                $next_update = $progress->update($count)
                  if $count >= $next_update;

                #=====================================================
                #    DATA TESTING - ABSTRACT OUT AND ENCAPSULATE
                #=====================================================
                my $pk_str = $obj->pk_str;
                $l4p->info('Reloading record from new DB for comparison');
                my $newobj = try { $cfgmgr->newdb->load($classobj, $obj->primary_key_to_terms) }
                           catch { $l4p->error($_, l4mtdump($obj->properties)) };
                foreach my $k ( keys %{$obj->get_values} ) {
                    $l4p->debug("Comparing $class $pk_str $k values");
                    use Test::Deep::NoTest;
                    my $diff = ref($obj->$k) ? (eq_deeply($obj->$k, $newobj->$k)?'':1)
                                             : DBI::data_diff($obj->$k, $newobj->$k);
                    if ( $diff ) {
                        unless ($obj->$k eq '' and $newobj->$k eq '') {
                            $l4p->error(sprintf(
                                'Data difference detected in %s ID %d %s!',
                                $class, $obj->id, $k, $diff
                            ));
                            $l4p->error($diff);
                            $l4p->error('a: '.$obj->$k);
                            $l4p->error('b: '.$newobj->$k);
                        }
                    }
                }
                #=====================================================
            }
            ###l4p $l4p->info($classobj->class.' object migration complete');

            $cfgmgr->post_load( $classobj );
        }
        $cfgmgr->post_load( $classmgr );

        $l4p->info("Done copying data! All went well.");
    }
    catch {
        $l4p->error("An error occurred while loading data: $_");
        exit 1;
    };

    $progress->update($max)
      if $max >= $next_update;

    print "Object counts: ".p($cfgmgr->object_summary);
}

1;

__END__

=head1 NAME

convert-db - A tool to convert backend database of Movable Type

=head1 SYNOPSIS

convert-db --new=mt-config.cgi.new [--old=mt-config.cgi.current]

=head1 DESCRIPTION

I<convert-db> is a tool to convert database of Movable Type to
others.  It is useful when it is necessary to switch like from
MySQL to PostgreSQL.

The following options are available:

  --new       mt-config.cgi file of destination
  --old       mt-config.cgi file of source (optional)

It is also useful to replicate Movable Type database.

=cut
