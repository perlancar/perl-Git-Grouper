package Git::Grouper;

use 5.010001;
use strict;
use warnings;
use Log::ger;

use Exporter qw(import);
use File::chdir;
use Perinci::Object qw(envresmulti);

# AUTHORITY
# DATE
# DIST
# VERSION

our @EXPORT_OK = qw(git_grouper_group);

our %SPEC;

$SPEC{':package'} = {
    v => 1.1,
    summary => 'Categorize git repositories into one/more groups and perform actions on them',
};

our %argspecs_common = (
    config_file => {
        schema => 'filename*',
    },
    config => {
        schema => 'hash*',
    },
);

our %argspecopt_detail = (
    detail => {
        schema => 'bool*',
        cmdline_aliases => {l=>{}},
    },
);

our %argspec0plus_repo = (
    repo => {
        schema => ['array*' => of=> 'str*'],
        pos => 0,
        slurpy => 1,
    },
);

our %argspec1plus_repo = (
    repo => {
        schema => ['array*' => of=> 'str*'],
        pos => 1,
        slurpy => 1,
    },
);

our %argspec0_group = (
    group => {
        schema => 'identifier127*',
        pos => 0,
    },
);

sub _parse_config {
    my $path = shift;

    my $config = {
        groups => [],
        remotes => {},
    };
    my $cursection;
    my $cursectiontype;
    my ($curgroup, $curremote);
    my $callback = sub {
        my %cbargs = @_;
        my $event = $cbargs{event};
        if ($event eq 'section') {
            $cursection = $cbargs{section};
            if ($cursection =~ /^group\b/) {
                $cursectiontype = 'group';
                if ($cursection =~ /^group \s+ "?(\w+)"?$/x) {
                    my $groupname = $1;
                    for my $g (@{ $config->{groups} }) {
                        if ($g->{group} eq $groupname) {
                            $curgroup = $g;
                            return;
                        }
                    }
                    $curgroup = { group => $groupname };
                    push @{ $config->{groups} }, $curgroup;
                    return;
                } else {
                    die "Invalid group section $cursection, please use 'group \"foo\"'";
                }
            } elsif ($cursection =~ /^remote\b/) {
                $cursectiontype = 'remote';
                if ($cursection =~ /^remote \s+ "?(\w+)"?$/x) {
                    $curremote = $1;
                    return;
                } else {
                    die "Invalid remote section $cursection, please use 'remote \"foo\"'";
                }
            } else {
                die "Unknown config section '$cursection'";
            }
        } elsif ($event eq 'key') {
            if ($cursectiontype eq 'group') {
                my $key = $cbargs{key};
                my $val = $cbargs{val};
                if ($key =~ /^(repo_name_pattern)/) {
                    $val = Regexp::From::String::str_to_re($val);
                }
                $curgroup->{ $cbargs{key} } = $val;
            } elsif ($cursectiontype eq 'remote') {
                $config->{remotes}{ $curremote }{ $cbargs{key} } = $cbargs{val};
            }
        }
    };

    eval {
        my $reader = Config::IOD::Reader->new;
        $reader->read_file($path, $callback);
    };
    if ($@) { return [500, "Error in configuration file '$path': $@"] }

    [200, "OK", $config];
}

sub _read_config {
    require Config::IOD::Reader;
    require Regexp::From::String;

    my %args = @_;

    my $config;
    if ($args{config}) {
        $config = $args{config};
    } else {
        my $config_file;
        if ($args{config_file}) {
            $config_file = $args{config_file};
        } else {
            my $found;
            my @paths = ("$ENV{HOME}/.config", $ENV{HOME}, "/etc");
            for my $path (@paths) {
                log_trace "Searching for configuration file in $path ...";
                if (-f "$path/git-grouper.conf") {
                    log_debug "Found configuration file at $path/git-grouper.conf ...";
                    $config_file = "$path/git-grouper.conf";
                    $found++;
                    last;
                }
            }
            unless ($found) {
                return [400, "Can't find config file (searched ".join(", ", @paths).")"];
            }
        }
        my $res = _parse_config($config_file);
        return $res unless $res->[0] == 200;
        $config = $res->[2];
    }
    [200, "OK", $config];
}

sub _get_repos {
    require App::GitUtils;

    my %args = @_;

    my @repos;
    my $multi;
    if ($args{repo}) {
        if (ref $args{repo} eq 'ARRAY') {
            push @repos, @{ $args{repo} };
            $multi++;
        } else {
            push @repos, $args{repo};
        }
    } else {
        push @repos, ".";
    }
    [200, "OK", \@repos];
}

$SPEC{ls_groups} = {
    v => 1.1,
    summary => 'List defined groups',
    args => {
        %argspecopt_detail,
    },
    args_rels => {
        choose_one => [qw/config_file config/],
    },
};
sub ls_groups {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }

    my @res;
    for my $group (@{ $config->{groups} }) {
        push @res, {name=>$group->{group}, summary=>$group->{summary}};
    }
    @res = map { $_->{name} } @res unless $args{detail};
    [200, "OK", \@res];
}

$SPEC{get_repo_group} = {
    v => 1.1,
    summary => 'Determine the group(s) of specified repos',
    args => {
        %argspec0plus_repo,
    },
};
sub get_repo_group {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }
    my $repos;  { my $res = _get_repos(%args); return $res unless $res->[0] == 200; $repos = $res->[2] }

    my @res;
  REPO:
    for my $repo0 (@$repos) {
        local $CWD = $repo0;

        my $repo;
        {
            my $res = App::GitUtils::info();
            unless ($res->[0] == 200) {
                #$envres->add_result($res->[0], $res->[1], {item_id=>$repo});
                #next REPO;
                return [500, "Can't get info for repo '$repo': $res->[0] - $res->[1]"];
            }
            $repo = $res->[2]{repo_name};
        }

        my @repo_groups = map { my $val = $_; $val =~ s/^\.group-//; $val } glob(".group-*");

        my $res = { repo0 => $repo0, repo => $repo, groups => [@repo_groups] };

      GROUP:
        for my $group (@{ $config->{groups} }) {
            next if grep { $_ eq $group->{group} } @repo_groups;

            log_trace "Matching repo %s with group %s ...", $repo, $group->{group};
            if ($group->{repo_name_pattern}) {
                if ($repo !~ $group->{repo_name_pattern}) {
                    log_trace "  Skipped group %s (repo %s does not match repo_name_pattern pattern %s)", $group->{group}, $repo, $group->{repo_name_pattern};
                    next GROUP;
                }
            }

            my @repo_tags = map { my $val = $_; $val =~ s/^\.tag-//; $val } glob(".tag-*");
            #log_trace "Repo's tags: %s", \@repo_tags;
            if ($group->{has_all_tags}) {
                for my $tag (@{ $group->{has_all_tags} }) {
                    if (!(grep { $_ eq $tag } @repo_tags)) {
                        #log_trace "  Skipped group %s (repo %s lacks tag %s)", $group->{group}, $repo, $tag;
                        next GROUP;
                    }
                }
            }
            if ($group->{lacks_all_tags}) {
                for my $tag (@{ $group->{lacks_all_tags} }) {
                    if (grep { $_ eq $tag } @repo_tags) {
                        #log_trace "  Skipped group %s (repo %s has tag %s)", $group->{group}, $repo, $tag;
                        next GROUP;
                    }
                }
            }
            if ($group->{has_any_tags}) {
                for my $tag (@{ $group->{has_any_tags} }) {
                    if (grep { $_ eq $tag } @repo_tags) {
                        #log_trace "  Including group %s (repo %s has tag %s)", $group->{group}, $repo, $tag;
                        goto SATISFY_FILTER_HAS_ANY_TAGS;
                    }
                }
                #log_trace "  Skipped group %s (repo %s does not have any tag %s)", $group->{group}, $repo, $group->{has_any_tags};
                next GROUP;
              SATISFY_FILTER_HAS_ANY_TAGS:
            }

            if ($group->{has_any_tags}) {
                for my $tag (@{ $group->{lacks_any_tags} }) {
                    if (!(grep { $_ eq $tag } @repo_tags)) {
                        #log_trace "  Including group %s (repo %s lacks tag %s)", $group->{group}, $repo, $tag;
                        goto SATISFY_FILTER_LACKS_ANY_TAGS;
                    }
                }
                #log_trace "  Skipped group %s (repo %s does not lack any tag %s)", $group->{group}, $repo, $group->{lacks_any_tags};
                next GROUP;
              SATISFY_FILTER_LACKS_ANY_TAGS:
            }

          MATCH_GROUP:
            push @{ $res->{groups} }, $group->{group};
        } # FIND_GROUP

        push @res, $res;
    } # REPO
    #$envres->as_struct;

    for (@res) {
        if (@{ $_->{groups} } == 0) {
            $_->{groups} = "";
        } elsif (@{ $_->{groups} } == 1) {
            $_->{groups} = $_->{groups}[0];
        }
    }
    unless (@res > 1) {
        @res = map { $_->{groups} } @res;
    }

    [200, "OK", \@res];
}

1;
# ABSTRACT:

=head1 SYNOPSIS

See the included script L<git-grouper>.


=head1 DESCRIPTION


=head1 append:SEE ALSO

L<Git::Bunch>

L<Acme::CPANModules::ManagingMultipleRepositories>
