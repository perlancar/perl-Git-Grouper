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

sub _parse_config {
    require Config::IOD::Reader;
    require Regexp::From::String;

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

$SPEC{get_repo_group} = {
    v => 1.1,
    summary => 'Group one/more repositories according to rules',
    description => <<'MARKDOWN',

Given an <pm:IOD> configuration file in *~/.config/git-grouper.conf* like this:

    [remote "github"]
    url_template = git@github.com:[% github_username %]/[% repo_name %].git
    fetch = +refs/heads/*:refs/remotes/origin/*

    [remote "github_company1"]
    url_template = git@github.com+company1:company1/[% repo_name %].git
    fetch = +refs/heads/*:refs/remotes/origin/*

    [remote "privbak"]
    url_template = ssh://u1@hostname:/path/to/[% repo_name %].git
    fetch = +refs/heads/*:refs/remotes/gitbak/*

    [group "company1"]
    repo_name_pattern = /^company1-/
    remotes = ["github_company1", "privbak"]
    username = foo
    email = foo@company1.com

    [group "perl"]
    repo_name_pattern = /^perl-/
    github_username = perlancar
    remotes = ["github", "privbak"]
    username = perlancar
    email = perlancar@gmail.com

    [group "other"]
    repo_name_pattern = /^./
    remotes = ["privbak"]
    username = foo
    email = foo@example.com

Suppose we are now at */home/u1/repos/perl-Git-Grouper*. This code:

    my $res = git_grouper_group(config_file => "/home/u1/.config/git-grouper.conf");

will check the git repository in the current directory and return something
like:

    $res = [200, "OK", "perl"];

To check multiple repositories:

    my $res = git_grouper_group(config_file => "/home/u1/.config/git-grouper.conf", repo => ["/home/u1/repos/perl-Git-Grouper", "repo2"]);

MARKDOWN
    args => {
        config_file => {
            schema => 'filename*',
        },
        config_file => {
            schema => 'hash*',
        },
        repo => {
            schema => ['array*' => of=> 'str*'],
            pos => 0,
            slurpy => 1,
        },
    },
    args_rels => {
        req_one => [qw/config_file config/],
    },
};
sub git_grouper_group {
    require App::GitUtils;

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

    #my $envres = envresmulti();
    my @groups;
  REPO:
    for my $repo (@repos) {
        local $CWD = $repo;
        my $res = App::GitUtils::info();
        unless ($res->[0] == 200) {
            #$envres->add_result($res->[0], $res->[1], {item_id=>$repo});
            #next REPO;
            return [500, "Can't get info for repo '$repo': $res->[0] - $res->[1]"];
        }
        my $repo_name = $res->[2]{repo_name};

        my $matching_group;
        FIND_GROUP: {
              for my $group (@{ $config->{groups} }) {
                  #log_trace "Matching repo %s with group %s ...", $repo_name, $group->{group};
                  if ($group->{repo_name_pattern}) {
                      if ($repo_name =~ $group->{repo_name_pattern}) {
                          $matching_group = $group;
                          last FIND_GROUP;
                      }
                  }
              }
          } # FIND_GROUP
        if ($matching_group) {
            push @groups, $matching_group;
        } else {
            #$envres->add_result(404, "Can't find group for repo $repo_name", {item_id=>$repo});
            return [404, "Can't find group for repo name $repo_name"];
        }
    } # REPO
    #$envres->as_struct;
    [200, "OK", $multi ? \@groups : $groups[0]];
}

1;
# ABSTRACT:

=head1 SYNOPSIS


=head1 append:SEE ALSO

L<Git::Bunch>

L<Acme::CPANModules::ManagingMultipleRepositories>
