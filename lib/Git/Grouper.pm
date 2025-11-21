package Git::Grouper;

use 5.010001;
use strict;
use warnings;
use Log::ger;

use Exporter qw(import);
use File::chdir;
#use IPC::System::Options -log=>1, qw(system);
use IPC::System::Options qw(system);
use Proc::ChildError qw(explain_child_error);
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

our %argspecopt_ignore_nondirs = (
    ignore_nondirs => {
        schema => 'bool*',
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

our %argspec0_group_spec = (
    group_spec => {
        schema => 'str*',
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
                    $config->{groups_by_name}{$groupname} = $curgroup;
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

    if ($args{ignore_nondirs}) {
        @repos = grep {(-d $_)} @repos;
    }

    [200, "OK", \@repos];
}

sub _parse_group_spec {
    my $spec0 = shift;

    my $group_spec = {op=>'and', groups=>[]};
    if ($spec0 =~ /\A\w+(?:\s*\&\s*\w+)*\z/) {
        $group_spec->{groups} = [split /\s*\&\s*/, $spec0];
    } elsif ($spec0 =~ /\A\w+(?:\s*\|\s*\w+)*\z/) {
        $group_spec->{op} = 'or';
        $group_spec->{groups} = [split /\s*\|\s*/, $spec0];
    } else {
        return [400, "Invalid group specification $spec0, please use G1|G2|... or G1&G2&..."];
    }

    [200, "OK", $group_spec];
}

$SPEC{ls_all_groups} = {
    v => 1.1,
    summary => 'List all defined groups',
    args => {
        %argspecs_common,
        %argspecopt_detail,
    },
    args_rels => {
        choose_one => [qw/config_file config/],
    },
};
sub ls_all_groups {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }

    my @res;
    for my $group (@{ $config->{groups} }) {
        push @res, {name=>$group->{group}, summary=>$group->{summary}};
    }
    @res = map { $_->{name} } @res unless $args{detail};
    [200, "OK", \@res];
}

$SPEC{ls_all_remotes} = {
    v => 1.1,
    summary => 'List all defined remotes',
    args => {
        %argspecs_common,
        %argspecopt_detail,
    },
    args_rels => {
        choose_one => [qw/config_file config/],
    },
};
sub ls_all_remotes {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }

    my @res;
    for my $remotename (sort keys %{ $config->{remotes} }) {
        my $remote = $config->{remotes}{$remotename};
        push @res, {
            name => $remotename,
            summary => $remote->{summary},
            url => $remote->{url},
            url_template => $remote->{url_template},
        };
    }
    @res = map { $_->{name} } @res unless $args{detail};
    [200, "OK", \@res];
}

$SPEC{ls_repo_groups} = {
    v => 1.1,
    summary => 'List the group(s) of specified repos',
    args => {
        %argspecs_common,
        %argspec0plus_repo,
        %argspecopt_ignore_nondirs,
        result_array => {
            summary => 'How to return result',
            schema => ['str*', in=>['auto','always']],
            default => 'auto',
            description => <<'MARKDOWN',

If set to 'auto', then when there is only one repo, will not return an array but
the groups directly. When set to 'always', will always return an array of
records.

MARKDOWN
        },
        groups_array => {
            summary => 'How to return groups',
            schema => ['str*', in=>['never', 'auto','always']],
            default => 'never',
            description => <<'MARKDOWN',

When set to 'never', will always return a string where multiple groups are
written as comma-separated list ('', 'group1', 'group1,group2'). When set to
'auto', will return either an empty string when there is no group, or string for
a single group, or array for multiple groups. When set to 'always', will always
return an array for the groups result.

MARKDOWN
        },
    },
};
sub ls_repo_groups {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }
    my $repos;  { my $res = _get_repos(%args); return $res unless $res->[0] == 200; $repos = $res->[2] }
    my $result_array = $args{result_array} // 'auto';
    my $groups_array = $args{groups_array} // 'never';

    my $payload = [];
  REPO:
    for my $repo0 (@$repos) {
        local $CWD = $repo0;

        my $repo;
        {
            my $res = App::GitUtils::info();
            unless ($res->[0] == 200) {
                #$envres->add_result($res->[0], $res->[1], {item_id=>$repo});
                #next REPO;
                return [500, "Can't get info for repo '$repo0': $res->[0] - $res->[1]"];
            }
            $repo = $res->[2]{repo_name};
        }

        my @repo_groups = map { my $val = $_; $val =~ s/^\.group-//; $val } glob(".group-*");
        my @repo_exclude_groups = map { my $val = $_; $val =~ s/^\.exclude-group-//; $val } glob(".exclude-group-*");
        my $exclude_all_other_groups = -f ".exclude-all-other-groups";

        my $res = { repo0 => $repo0, repo => $repo, groups => [@repo_groups] };

      GROUP:
        for my $group (@{ $config->{groups} }) {
            next if $exclude_all_other_groups;
            next if grep { $_ eq $group->{group} } @repo_groups;

            my $num_filters;

            log_trace "Matching repo %s with group %s ...", $repo, $group->{group};
            if ($group->{repo_name_pattern}) {
                $num_filters++;
                if ($repo !~ $group->{repo_name_pattern}) {
                    log_trace "  Skipped group %s (repo %s does not match repo_name_pattern pattern %s)", $group->{group}, $repo, $group->{repo_name_pattern};
                    next GROUP;
                }
            }

            my @repo_tags = map { my $val = $_; $val =~ s/^\.tag-//; $val } glob(".tag-*");
            log_trace "  Repo's tags: %s", \@repo_tags;
            if ($group->{has_all_tags}) {
                $num_filters++;
                for my $tag (@{ $group->{has_all_tags} }) {
                    if (!(grep { $_ eq $tag } @repo_tags)) {
                        log_trace "  Skipped group %s (repo %s lacks tag %s)", $group->{group}, $repo, $tag;
                        next GROUP;
                    }
                }
            }
            if ($group->{lacks_all_tags}) {
                $num_filters++;
                for my $tag (@{ $group->{lacks_all_tags} }) {
                    if (grep { $_ eq $tag } @repo_tags) {
                        log_trace "  Skipped group %s (repo %s has tag %s)", $group->{group}, $repo, $tag;
                        next GROUP;
                    }
                }
            }
            if ($group->{has_any_tags}) {
                $num_filters++;
                for my $tag (@{ $group->{has_any_tags} }) {
                    if (grep { $_ eq $tag } @repo_tags) {
                        log_trace "  Including group %s (repo %s has tag %s)", $group->{group}, $repo, $tag;
                        goto SATISFY_FILTER_HAS_ANY_TAGS;
                    }
                }
                log_trace "  Skipped group %s (repo %s does not have any tag %s)", $group->{group}, $repo, $group->{has_any_tags};
                next GROUP;
              SATISFY_FILTER_HAS_ANY_TAGS:
            }

            if ($group->{lacks_any_tags}) {
                $num_filters++;
                for my $tag (@{ $group->{lacks_any_tags} }) {
                    if (!(grep { $_ eq $tag } @repo_tags)) {
                        log_trace "  Including group %s (repo %s lacks tag %s)", $group->{group}, $repo, $tag;
                        goto SATISFY_FILTER_LACKS_ANY_TAGS;
                    }
                }
                log_trace "  Skipped group %s (repo %s does not lack any tag %s)", $group->{group}, $repo, $group->{lacks_any_tags};
                next GROUP;
              SATISFY_FILTER_LACKS_ANY_TAGS:
            }

            # this must be the last filter
          EXCLUDE_GROUPS:
            if (grep { $group->{group} eq $_ } @repo_exclude_groups) {
                log_trace "  Skipped group %s (repo %s has .exclude-group-%s)", $group->{group}, $repo, $group->{group};
                next GROUP;
            }

          MATCH_GROUP:
            if ($num_filters) {
                log_trace "  Group $group->{group} matches";
                push @{ $res->{groups} }, $group->{group};
            } else {
                log_trace "  Group $group->{group} does NOT match (no filters satisfied)";
            }
        } # FIND_GROUP

      CHECK_GROUPS: {
            for my $groupname (@{ $res->{groups} }) {
                unless ($config->{groups_by_name}{$groupname}) {
                    return [400, "Repo $repo: Undefined group in configuration: '$groupname"];
                }
            }
        }

        push @$payload, $res;
    } # REPO
    #$envres->as_struct;

    for (@$payload) {
        if ($groups_array eq 'auto') {
            if (@{ $_->{groups} } == 0) {
                $_->{groups} = "";
            } elsif (@{ $_->{groups} } == 1) {
                $_->{groups} = $_->{groups}[0];
            }
        } elsif ($groups_array eq 'never') {
            $_->{groups} = join ",", @{ $_->{groups} };
        }
    }

    if ($result_array eq 'auto') {
        unless (@$payload > 1) {
            $payload = $payload->[0]{groups};
        }
    }

    [200, "OK", $payload];
}

$SPEC{filter_repo_has_group} = {
    v => 1.1,
    summary => 'Only list repos that belong to specified group(s)',
    args => {
        %argspecs_common,
        %argspec0_group_spec,
        %argspec1plus_repo,
        %argspecopt_ignore_nondirs,
    },
};
sub filter_repo_has_group {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }
    my $group_spec; { my $res = _parse_group_spec($args{group_spec}); return $res unless $res->[0] == 200; $group_spec = $res->[2] }
    my $rows; { my $res = ls_repo_groups(%args, config => $config, result_array=>'always', groups_array=>'always'); return $res unless $res->[0] == 200; $rows = $res->[2] }

    my @repos;
  REPO:
    for my $row (@$rows) {
        #use DD; dd \@repo_groups;
        #log_trace "Filtering repo %s (groups=%s) ...", $row->{repo0}, \@{ $row->{groups} };

        my $match;
      GROUP:
        if ($group_spec->{op} eq 'and') {
            for my $group (@{ $group_spec->{groups} }) {
                if ($group_spec->{op} eq 'and') {
                    next REPO unless grep { $group eq $_ } @{ $row->{groups} };
                }
            }
            $match++;
        } else {
            # or
            for my $group (@{ $group_spec->{groups} }) {
                do { $match++; last } if grep { $group eq $_ } @{ $row->{groups} };
            }
        }
        next unless $match;
        push @repos, $row->{repo0};
    }

    [200, "OK", \@repos];
}

$SPEC{filter_repo_lacks_group} = {
    v => 1.1,
    summary => 'Only list repos that do not belong to specified group(s)',
    args => {
        %argspecs_common,
        %argspec0_group_spec,
        %argspec1plus_repo,
        %argspecopt_ignore_nondirs,
    },
};
sub filter_repo_lacks_group {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }
    my $group_spec; { my $res = _parse_group_spec($args{group_spec}); return $res unless $res->[0] == 200; $group_spec = $res->[2] }
    my $rows; { my $res = ls_repo_groups(%args, config => $config, result_array=>'always', groups_array=>'always'); return $res unless $res->[0] == 200; $rows = $res->[2] }

    my @repos;
  REPO:
    for my $row (@$rows) {
        log_trace "Filtering repo %s (groups=%s) ...", $row->{repo0}, $row->{groups};

        my $match;
      GROUP:
        if ($group_spec->{op} eq 'and') {
            for my $group (@{ $group_spec->{groups} }) {
                if ($group_spec->{op} eq 'and') {
                    next REPO if grep { $group eq $_ } @{ $row->{groups} };
                }
            }
            $match++;
        } else {
            # or
            for my $group (@{ $group_spec->{groups} }) {
                do { $match++; last } unless grep { $group eq $_ } @{ $row->{groups} };
            }
        }
        next unless $match;
        push @repos, $row->{repo0};
    }

    [200, "OK", \@repos];
}

$SPEC{filter_repo_orphan} = {
    v => 1.1,
    summary => 'Only list repos that do not belong to any group(s)',
    args => {
        %argspecs_common,
        %argspec0plus_repo,
        %argspecopt_ignore_nondirs,
    },
};
sub filter_repo_orphan {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }
    my $rows; { my $res = ls_repo_groups(%args, config => $config, result_array=>'always', groups_array=>'always'); return $res unless $res->[0] == 200; $rows = $res->[2] }

    my @repos;
  REPO:
    for my $row (@$rows) {
        next unless @{ $row->{groups} } == 0;
        push @repos, $row->{repo0};
    }

    [200, "OK", \@repos];
}

$SPEC{filter_repo_not_orphan} = {
    v => 1.1,
    summary => 'Only list repos that belong to at least one group',
    args => {
        %argspecs_common,
        %argspec0plus_repo,
        %argspecopt_ignore_nondirs,
    },
};
sub filter_repo_not_orphan {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }
    my $rows; { my $res = ls_repo_groups(%args, config => $config, result_array=>'always', groups_array=>'always'); return $res unless $res->[0] == 200; $rows = $res->[2] }

    my @repos;
  REPO:
    for my $row (@$rows) {
        next if @{ $row->{groups} } == 0;
        push @repos, $row->{repo0};
    }

    [200, "OK", \@repos];
}

$SPEC{filter_repo_multiple_group} = {
    v => 1.1,
    summary => 'Only list repos that belong to at least two groups',
    args => {
        %argspecs_common,
        %argspec0plus_repo,
        %argspecopt_ignore_nondirs,
    },
};
sub filter_repo_multiple_group {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }
    my $rows; { my $res = ls_repo_groups(%args, config => $config, _always_array=>1); return $res unless $res->[0] == 200; $rows = $res->[2] }

    my @repos;
  REPO:
    for my $row (@$rows) {
        next unless @{ $row->{groups} } > 1;
        push @repos, $row->{repo0};
    }

    [200, "OK", \@repos];
}

$SPEC{filter_repo_single_group} = {
    v => 1.1,
    summary => 'Only list repos that belong to just a single group',
    args => {
        %argspecs_common,
        %argspec0plus_repo,
        %argspecopt_ignore_nondirs,
    },
};
sub filter_repo_single_group {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }
    my $rows; { my $res = ls_repo_groups(%args, config => $config, result_array=>'always', groups_array=>'always'); return $res unless $res->[0] == 200; $rows = $res->[2] }

    my @repos;
  REPO:
    for my $row (@$rows) {
        next unless @{ $row->{groups} } == 1;
        push @repos, $row->{repo0};
    }

    [200, "OK", \@repos];
}

sub _fill_template {
    require Template;

    my ($str, $vars) = @_;

    state $template = Template->new({
    });

    my $output;
    $template->process(\$str, $vars, \$output) or die "Can't process template $str: ".$template->error;
    $output;
}

sub _configure_repo_single {
    my ($row, $config, $args) = @_;

    local $CWD = $row->{repo0};

    for my $groupname (@{ $row->{groups} }) {
        my $group = $config->{groups_by_name}{$groupname};

      SET_USERNAME: {
            last unless defined $group->{user_name};
            log_info "  Setting user.name to %s", $group->{user_name};
            system("git", "config", "set", "user.name", $group->{user_name});
            log_error("Can't set user.name: %s", explain_child_error()) if $?;
        }

      SET_EMAIL: {
            last unless defined $group->{user_email};
            log_info "  Setting user.email to %s", $group->{user_email};
            system("git", "config", "set", "user.email", $group->{user_email});
            log_error("Can't set user.email: %s", explain_child_error()) if $?;
        }
        next;

      SET_REMOTES: {
            last unless $group->{remotes};

            my %configured_remotes;
            my @existing_remotes;
            {
                system({capture_stdout=>\my $out}, "git", "remote");
                chomp(@existing_remotes = split /^/m, $out);
                log_trace "Existing remotes: %s", \@existing_remotes;
            }

            if ($args->{clean_remotes}) {
                for my $remotename (@existing_remotes) {
                    log_info "  Deleting remote $remotename first";
                    system "git", "remote", "remove", $remotename;
                    log_error("Can't remove remote %s: %s", $remotename, explain_child_error()) if $?;
                }
                @existing_remotes = ();
            }

            my $i = -1;
            for my $remotename (@{ $group->{remotes} }) {
                my $remote = $config->{remotes}{$remotename};
                unless ($remote) {
                    log_error "  Skipped adding remote '$remotename': undefined in config";
                    next;
                }
                $i++;
                log_debug "  Adding/setting remote $remotename ...";

                my $url = $remote->{url} ? $remote->{url} :
                    $remote->{url_template} ? _fill_template($remote->{url_template}, $row) : undef;
                #log_trace "  URL=%s", $url;
                unless ($url) {
                    log_error "  Skipped adding remote '$remote': undefined url/url_template";
                    next;
                }

                my @remotenames_to_set = ($remotename);
                unshift @remotenames_to_set, "origin" if $i == 0; # origin is always set to the first (main) remote

                for my $remotename_to_set (@remotenames_to_set) {
                    if (grep {$_ eq $remotename_to_set} @existing_remotes) {
                        log_info "  Setting URL of remote $remotename_to_set to $url";
                        system "git", "remote", "set-url", $remotename_to_set, $url;
                        log_error("Can't set url of remote %s: %s", $remotename_to_set, explain_child_error()) if $?;
                    } else {
                        log_info "  Adding remote $remotename_to_set: $url";
                        system "git", "remote", "add", $remotename_to_set, $url;
                        log_error("Can't add remote %s: %s", $remotename_to_set, explain_child_error()) if $?;
                    }
                    $configured_remotes{$remotename_to_set}++;
                } # for $remotename_to_set
            } # for $remotename
        } # SET_REMOTES

    } # for $groupname
    [200];
}

$SPEC{ls_repo_remotes} = {
    v => 1.1,
    summary => "List remotes of specified repos based on group configuration",
    args => {
        %argspec0plus_repo,
        %argspecopt_ignore_nondirs,
        result_array => {
            schema => ['str*', in=>['auto', 'always']],
        },
        # TODO: detail
    },
};
sub ls_repo_remotes {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }
    my $rows; { my $res = ls_repo_groups(%args, config => $config, result_array=>'always', groups_array=>'always'); return $res unless $res->[0] == 200; $rows = $res->[2] }
    my $result_array = $args{result_array} // 'auto';

    my $payload = [];
  REPO:
    for my $row (@$rows) {
        my $rowres = {repo0 => $row->{repo0}, repo => $row->{repo}, remotes => []};
        for my $groupname (@{ $row->{groups} }) {
            my $group = $config->{groups_by_name}{$groupname};
            next unless $group->{remotes};
            for my $remote (@{ $group->{remotes} }) {
                next if grep { $_ eq $remote } @{ $rowres->{remotes} };
                push @{ $rowres->{remotes} }, $remote;
            }
        }
        push @$payload, $rowres;
    }

    if ($result_array eq 'auto') {
        unless (@$payload > 1) {
            $payload = $payload->[0]{remotes};
        }
    }

    [200, "OK", $payload];
}

$SPEC{configure_repo} = {
    v => 1.1,
    summary => "Configure repo based on group's attributes",
    args => {
        %argspecs_common,
        %argspec0plus_repo,
        %argspecopt_ignore_nondirs,
        clean_remotes => {
            summary => 'Delete all remotes not specified by the group configuration',
            schema => 'bool*',
        },
    },
};
sub configure_repo {
    my %args = @_;
    my $config; { my $res = _read_config(%args); return $res unless $res->[0] == 200; $config = $res->[2] }
    my $rows; { my $res = ls_repo_groups(%args, config => $config, result_array=>'always', groups_array=>'always'); return $res unless $res->[0] == 200; $rows = $res->[2] }

    my $envres = envresmulti();
    my $i = 0;
  REPO:
    for my $row (@$rows) {
        $i++;
        last if $i > 1;
        log_info "Configuring repo %s (group=%s) ...", $row->{repo0}, $row->{groups};
        if ($row->{groups} eq '') {
            log_debug "  Skipping repo because it does not belong to any group";
            next REPO;
        }
        my $res = _configure_repo_single($row, $config, \%args);
        $envres->add_result($res->[0], $res->[1], {item_id=>$row->{repo}});
    }
    $envres->as_struct;
}

1;
# ABSTRACT:

=head1 SYNOPSIS

See the included script L<git-grouper>.


=head1 DESCRIPTION


=head1 append:SEE ALSO

L<Git::Bunch>

L<Acme::CPANModules::ManagingMultipleRepositories>
