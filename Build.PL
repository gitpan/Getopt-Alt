use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name       => 'Getopt::Alt',
    license           => 'perl',
    dist_author       => 'Ivan Wills <ivan.wills@gmail.com>',
    dist_version_from => 'lib/Getopt/Alt.pm',
    requires => {
        'perl'                => '5.006',
        'Config::Any'         => 0,
        'File::HomeDir'       => 0,
        'List::MoreUtils'     => 0,
        'List::Util'          => 0,
        'Moose'               => 0,
        'Moose::Role'         => 0,
        'Path::Tiny'          => 0,
        'Scalar::Util'        => 0,
        'Tie::Handle::Scalar' => 0,
        'Try::Tiny'           => 0,
        'parent'              => 0,
        'version'             => 0,
    },
    configure_requires => {
        'Module::Build' => 0.38,
    },
    build_requires => {
        'Test::More'     => 0,
        'Test::Warnings' => 0,
    },
    recommends => {
        'Test::Spelling'     => 0,
        'Test::Perl::Critic' => 0,
        'Test::Kwalitee'     => 0,
        'Pod::Coverage'      => 0,
    },
    add_to_cleanup     => [ 'Getopt-Alt-*' ],
    create_makefile_pl => 'traditional',
    create_license     => 1,
    meta_merge         => {
        resources => {
            repository => 'git://github.com/ivanwills/Getopt-Alt.git',
            bugtracker => 'http://rt.cpan.org/NoAuth/Bugs.html?Dist=Getopt-Alt',
        },
    },
);

$builder->create_build_script();
