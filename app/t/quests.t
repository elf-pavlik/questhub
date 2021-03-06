use 5.010;

use lib 'lib';
use Play::Test::App;
use parent qw(Test::Class);

use Play::DB qw(db);
use XML::LibXML;

sub setup :Tests(setup => no_plan) {
    Dancer::session->destroy;
    reset_db();
}

sub _fill_common_quests {
    my $self = shift;
    my $quests_data = {
        1 => {
            name    => 'name_1',
            user    => 'user_1',
            status  => 'open',
            realm => 'europe',
        },
        2 => {
            name    => 'name_2',
            user    => 'user_2',
            status  => 'open',
            tags    => ['bug'],
            realm => 'europe',
        },
        3 => {
            name    => 'name_3',
            user    => 'user_3',
            status  => 'closed',
            realm => 'europe',
        },
    };

    # insert quests to DB
    for (keys %$quests_data) {
        http_json GET => "/api/fakeuser/$quests_data->{$_}{user}";

        delete $quests_data->{$_}{_id};
        my $result = db->quests->add($quests_data->{$_});
        $quests_data->{$_}{_id} = $result->{_id};
        $quests_data->{$_}{ts} = $result->{ts};
        $quests_data->{$_}{team} = $result->{team};
        delete $quests_data->{$_}{user};
    }
    return $quests_data;
}

sub quest_list :Tests {
    my @quests = (
        {
            name    => 'name_1',
            status  => 'open',
            realm => 'europe',
        },
        {
            name    => 'name_2',
            status  => 'open',
            tags    => ['bug'],
            realm => 'europe',
        },
        {
            name    => 'name_3',
            status  => 'closed',
            realm => 'europe',
        },
    );

    http_json GET => "/api/fakeuser/foo";
    http_json POST => '/api/quest', { params => $_ } for @quests;

    my $list = http_json GET => '/api/quest', { params => { realm => 'europe' } };

    cmp_deeply
        [
            sort { $a->{_id} cmp $b->{_id} } @$list
        ],
        [
            map {
                superhashof {
                    %$_,
                    author => 'foo',
                    team => ['foo'],
                    _id => ignore,
                    ts => re('^\d+$'),
                    status => 'open' # original status is ignored
                }
            } @quests
        ];
}

sub quest_list_filtering :Tests {
    my $self = shift;

    http_json GET => "/api/fakeuser/foo";
    my @quests = map { http_json POST => '/api/quest', { params => { name => "foo-$_", realm => 'europe' } } } 1..5;
    http_json POST => "/api/quest/$quests[$_]->{_id}/close" for 3, 4;
    http_json PUT => "/api/quest/$quests[1]->{_id}", { params => { tags => ['t1'] } };
    http_json PUT => "/api/quest/$quests[3]->{_id}", { params => { tags => ['t1', 't2'] } };

    http_json GET => "/api/fakeuser/bar";
    http_json POST => "/api/quest/$quests[$_]->{_id}/watch" for 0, 4;
    http_json GET => "/api/fakeuser/baz";
    http_json POST => "/api/quest/$quests[$_]->{_id}/watch" for 2, 4;

    my $list = http_json GET => '/api/quest', { params => { status => 'closed', realm => 'europe' } };
    cmp_deeply
        [ map { $_->{_id} } @$list ],
        [ map { $_->{_id} } @quests[4,3] ];

    $list = http_json GET => '/api/quest', { params => { tags => 't1', realm => 'europe' } };
    cmp_deeply
        [ map { $_->{_id} } @$list ],
        [ map { $_->{_id} } @quests[3,1] ];

    $list = http_json GET => '/api/quest', { params => { watchers => 'bar', realm => 'europe' } };
    cmp_deeply
        [ map { $_->{_id} } @$list ],
        [ map { $_->{_id} } @quests[4,0] ];
}

sub quest_sorting :Tests {
    my $self = shift;
    my $quests_data = $self->_fill_common_quests;

    http_json GET => '/api/fakeuser/user_3';
    http_json POST => '/api/quest/'.$quests_data->{2}{_id}.'/like';
    http_json POST => '/api/quest/'.$quests_data->{1}{_id}.'/comment', { params => { body => 'bah!' } };

    my $list = http_json GET => '/api/quest?sort=leaderboard&realm=europe';
    my @names = map { $_->{name} } @$list;
    is_deeply \@names, [qw/ name_2 name_1 name_3 /];
}

sub quest_list_limit_offset :Tests {
    my $self = shift;
    my $quests_data = $self->_fill_common_quests;

    my $list = http_json GET => '/api/quest?limit=2&realm=europe';
    is scalar @$list, 2;

    $list = http_json GET => '/api/quest?limit=2&offset=2&realm=europe';
    is scalar @$list, 1;

    $list = http_json GET => '/api/quest?limit=5&realm=europe';
    is scalar @$list, 3;
}

sub single_quest :Tests {
    my $self = shift;
    my $quests_data = $self->_fill_common_quests;

    my $id          =  $quests_data->{1}{_id};
    my $quest = http_json GET => '/api/quest/'.$id;

    cmp_deeply $quest, superhashof($quests_data->{1});
}

sub edit_quest :Tests {
    my $self = shift;
    my $quests_data = $self->_fill_common_quests;

    my $edited_quest = $quests_data->{1};
    my $id = $edited_quest->{_id};

    # Change
    local $edited_quest->{name} = 'name_11';
    local $edited_quest->{description} = 'description_11';

    Dancer::session login => $edited_quest->{team}[0];

    my $put_result = http_json PUT => "/api/quest/$id", { params => {
        name => $edited_quest->{name},
        description => $edited_quest->{description},
    } };
    cmp_deeply $put_result, { _id => $id }, 'put result';

    my $got_quest = http_json GET => "/api/quest/$id";
    cmp_deeply $got_quest, superhashof($edited_quest);
}


sub add_quest :Tests {
    my $user = 'user_4';
    my $new_record = {
        name    => 'name_4',
        status  => 'open',
        realm => 'europe',
        description => "Description.\n\nMore description.",
        points => 3,
    };

    http_json GET => "/api/fakeuser/$user";

    my $add_result = http_json POST => '/api/quest', { params => $new_record };

    cmp_deeply
        $add_result,
        {
            %$new_record,
            team => [$user],
            author => $user,
            _id => re('^\S+$'),
            ts => re('^\d+$'),
            bump => re('^\d+$'),
            base_points => 1, # impossible to set points through http API
            points => 1,
            entity => 'quest',
        },
        'add response';

    my $id = $add_result->{_id};

    my $got_quest = http_json GET => "/api/quest/$id";
    cmp_deeply
        $got_quest,
        {
            %$new_record,
            team => [$user],
            author => $user,
            _id => re('^\S+$'),
            ts => re('^\d+$'),
            bump => re('^\d+$'),
            base_points => 1,
            points => 1,
            entity => 'quest',
        },
        'get response';
}

sub quest_events :Tests {

    my $user = 'euser';
    http_json GET => "/api/fakeuser/$user";

    my $new_record = {
        name    => 'test-quest',
        status  => 'open',
        realm => 'europe',
    };

    Dancer::session login => $user;
    my $add_result = http_json POST => '/api/quest', { params => $new_record }; # create
    my $quest_id = $add_result->{_id};
    http_json POST => "/api/quest/$quest_id/close";
    http_json POST => "/api/quest/$quest_id/reopen";
    http_json POST => "/api/quest/$quest_id/abandon";
    http_json POST => "/api/quest/$quest_id/resurrect";

    my @events = @{ db->events->list({ realm => 'europe' }) };
    cmp_deeply \@events, [
        superhashof({
            _id => re('^\S+$'),
            ts => re('^\d+$'),
            type => 'add-comment',
            author => $user,
            comment => superhashof({ type => 'resurrect' }),
            quest => superhashof({ name => 'test-quest', status => 'open', team => [$user], author => $user }),
            realm => 'europe',
        }),
        superhashof({
            _id => re('^\S+$'),
            ts => re('^\d+$'),
            type => 'add-comment',
            author => $user,
            comment => superhashof({ type => 'abandon' }),
            quest => superhashof({ name => 'test-quest', status => 'open', team => [$user], author => $user }),
            realm => 'europe',
        }),
        superhashof({
            _id => re('^\S+$'),
            ts => re('^\d+$'),
            type => 'add-comment',
            author => $user,
            comment => superhashof({ type => 'reopen' }),
            quest => superhashof({ name => 'test-quest', status => 'open', team => [$user], author => $user }),
            realm => 'europe',
        }),
        superhashof({
            _id => re('^\S+$'),
            ts => re('^\d+$'),
            type => 'add-comment',
            author => $user,
            comment => superhashof({ type => 'close' }),
            quest => superhashof({ name => 'test-quest', status => 'open', team => [$user], author => $user }),
            realm => 'europe',
        }),
        superhashof({
            _id => re('^\S+$'),
            ts => re('^\d+$'),
            type => 'add-quest',
            author => $user,
            quest => superhashof({ name => 'test-quest', status => 'open', team => [$user], author => $user }),
            realm => 'europe',
        }),
        superhashof({
            type => 'add-user',
        }),
    ];
}

sub delete_quest :Tests {
    my $self = shift;
    my $quests_data = $self->_fill_common_quests;

    my $id_to_remove;
    my $user;
    {
        my $list_before_resp = dancer_response GET => '/api/quest?realm=europe';
        my $result = decode_json($list_before_resp->content);
        is scalar @$result, 3;
        $id_to_remove = $result->[1]{_id};
        $user = $result->[1]{team}[0];
        like $id_to_remove, qr/^[0-9a-f]{24}$/; # just an assertion
    }

    {
        my $delete_resp = dancer_response DELETE => "/api/quest/$id_to_remove";
        is $delete_resp->status, 500, "Can't delete a quest while not logged in";
    }

    {
        Dancer::session login => 'blah';
        http_json GET => "/api/fakeuser/blah";
        my $delete_resp = dancer_response DELETE => "/api/quest/$id_to_remove";
        is $delete_resp->status, 500, "Can't delete another user's quest";
    }

    {
        Dancer::session login => $user;
        http_json GET => "/api/fakeuser/$user";
        my $delete_resp = dancer_response DELETE => "/api/quest/$id_to_remove";
        is $delete_resp->status, 200, "Can delete the quest you own" or diag $delete_resp->content;
    }

    {
        my $list_after_resp = dancer_response GET => '/api/quest?realm=europe';
        is scalar @{ decode_json($list_after_resp->content) }, 2, 'deleted quests are not shown in list';
    }

    {
        my $delete_resp = dancer_response GET => "/api/quest/$id_to_remove";
        is $delete_resp->status, 500, "Can't fetch a deleted quest by its id";
    }
}

sub points :Tests {
    my $self = shift;
    my $quests_data = $self->_fill_common_quests;

    my $quest = $quests_data->{1}; # name_2, user_2

    http_json GET => "/api/fakeuser/".$quest->{team}[0];
    Dancer::session login => $quest->{team}[0];

    my $user = http_json GET => '/api/current_user';
    is $user->{rp}{europe}, 0;

    http_json POST => "/api/quest/$quest->{_id}/close";

    $user = http_json GET => '/api/current_user';
    is $user->{rp}{europe}, 1, 'got a point';

    http_json POST => "/api/quest/$quest->{_id}/reopen";
    $user = http_json GET => '/api/current_user';
    is $user->{rp}{europe}, 0, 'lost a point';

    my $like = sub {
        my ($quest, $user, $action) = @_;
        my $old_login = Dancer::session('login');
        http_json GET => "/api/fakeuser/$user";
        Dancer::session login => $user;
        http_json POST => "/api/quest/$quest->{_id}/$action";
        Dancer::session login => $old_login;
    };
    $like->($quest, 'other', 'like');
    $like->($quest, 'other2', 'like');

    $user = http_json GET => '/api/current_user';
    is $user->{rp}{europe}, 0, 'no points for likes on an open quest';

    http_json POST => "/api/quest/$quest->{_id}/close";
    $user = http_json GET => '/api/current_user';
    is $user->{rp}{europe}, 3, '1 + number-of-likes points for a closed quest';

    $like->($quest, 'other', 'unlike');
    $like->($quest, 'other3', 'like');
    $like->($quest, 'other4', 'like');
    $user = http_json GET => '/api/current_user';
    is $user->{rp}{europe}, 4, 'likes and unlikes apply to the closed quest, retroactively';

    http_json POST => "/api/quest/$quest->{_id}/reopen";
    $user = http_json GET => '/api/current_user';
    is $user->{rp}{europe}, 0, 'points are taken away if quest is reopened';

    http_json POST => "/api/quest/$quest->{_id}/close";
    $user = http_json GET => '/api/current_user';
    is $user->{rp}{europe}, 4, 'closed again, got points again...';

    http_json DELETE => "/api/quest/$quest->{_id}";
    $user = http_json GET => '/api/current_user';
    is $user->{rp}{europe}, 0, 'lost points after delete';
}

sub more_points :Tests {
    my $self = shift;
    my $quests_data = $self->_fill_common_quests;

   my $quest = $quests_data->{1};
    http_json GET => "/api/fakeuser/$quest->{team}[0]";

    my $user = http_json GET => '/api/current_user';
    is $user->{rp}{europe}, 0, 'zero points initially';

    http_json DELETE => "/api/quest/$quest->{_id}";
    $user = http_json GET => '/api/current_user';
    is $user->{rp}{europe}, 0, 'still zero points after removing an open quest';
}

sub quest_tags :Tests {
    http_json GET => '/api/fakeuser/user_1';

    http_json POST => '/api/quest', { params => {
        name => 'typed-quest',
        tags => ['blog', 'moose'],
        realm => 'europe',
    } };

    my $unknown_type_response = dancer_response POST => '/api/quest', { params => {
        name => 'typed-quest',
        tags => 'invalid',
        realm => 'europe',
    } };
    is $unknown_type_response->status, 500;
    like $unknown_type_response->content, qr/did not pass type constraint/;
}

sub cc :Tests {
    my $user = 'user_c';
    http_json GET => "/api/fakeuser/$user";
    Dancer::session login => $user;

    my $q1_result = http_json POST => '/api/quest', { params => {
        name => 'q1',
        realm => 'europe',
    } };
    my $q2_result = http_json POST => '/api/quest', { params => {
        name => 'q2',
        realm => 'europe',
    } };
    my $q3_result = http_json POST => '/api/quest', { params => {
        name => 'q3',
        realm => 'europe',
    } };

    http_json POST => "/api/quest/$q1_result->{_id}/comment", { params => { body => 'first comment!' } };
    http_json POST => "/api/quest/$q1_result->{_id}/comment", { params => { body => 'second comment on first quest!' } };
    http_json POST => "/api/quest/$q3_result->{_id}/comment", { params => { body => 'first comment on third quest!' } };

    my $list = http_json GET => "/api/quest?user=$user&realm=europe";
    my $list_with_cc = http_json GET => "/api/quest?user=$user&comment_count=1&realm=europe";
    is $list->[0]{comment_count}, undef;

    # default order is desc, so $list_with_cc->[0] is q3
    is $list_with_cc->[0]{comment_count}, 1;
    is $list_with_cc->[1]{comment_count}, undef;
    is $list_with_cc->[2]{comment_count}, 2;
}

sub email_like :Tests {

    http_json GET => "/api/fakeuser/foo";

    register_email 'foo' => { email => 'test@example.com', notify_comments => 0, notify_likes => 1 };

    my $quest = http_json POST => '/api/quest', { params => {
        name => 'q1',
        realm => 'europe',
    } };

    http_json GET => "/api/fakeuser/bar";

    http_json POST => "/api/quest/$quest->{_id}/like";

    my @deliveries = process_email_queue();
    is scalar(@deliveries), 1, '1 email sent';
    my $email = $deliveries[0];
    cmp_deeply $email->{envelope}, {
        from => 'notification@localhost',
        to => [ 'test@example.com' ],
    }, 'from & to addresses';

    like
        $email->{email}->get_body,
        qr/Reward for completing this quest is now 2/,
        'reward line in email body';

    # now let's close the quest and like it once more

    Dancer::session login => 'foo';
    http_json POST => "/api/quest/$quest->{_id}/close";

    http_json GET => "/api/fakeuser/bar2";

    http_json POST => "/api/quest/$quest->{_id}/like";

    @deliveries = process_email_queue();
    is scalar(@deliveries), 1, 'second email sent';
    $email = $deliveries[0];
    unlike
        $email->{email}->get_body,
        qr/Reward for completing this quest/,
        "no reward line in emails on completed quest's like";
    like
        $email->{email}->get_body,
        qr/you get one more point/,
        "'already completed' text in email";
}

sub join_leave :Tests {
    http_json GET => "/api/fakeuser/$_" for qw/ foo foo2 bar /;

    http_json GET => "/api/fakeuser/foo";

    my $quest = http_json POST => '/api/quest', { params => {
        name => 'q1',
        realm => 'europe',
    } };

    my $response;

    $response = dancer_response POST => "/api/quest/$quest->{_id}/join";
    is $response->status, 500;
    like $response->content, qr/unable to join a quest/;

    http_json POST => "/api/quest/$quest->{_id}/leave";

    my $got_quest = http_json GET => "/api/quest/$quest->{_id}";
    is $got_quest->{name}, 'q1', 'name is still untouched';
    is_deeply $got_quest->{team}, [], 'team is empty too';

    $response = dancer_response POST => "/api/quest/$quest->{_id}/leave";
    is $response->status, 500;
    like $response->content, qr/unable to leave quest/;

    my $list = http_json GET => "/api/quest?unclaimed=1&realm=europe";
    cmp_deeply $list, [$got_quest], 'listing unclaimed=1 option';

    http_json POST => "/api/quest/$quest->{_id}/like";

    http_json GET => "/api/fakeuser/bar";
    http_json POST => "/api/quest/$quest->{_id}/like";

    Dancer::session login => 'foo';

    $got_quest = http_json GET => "/api/quest/$quest->{_id}";
    is_deeply $got_quest->{likes}, ['foo', 'bar'];

    http_json POST => "/api/quest/$quest->{_id}/join";
    $list = http_json GET => "/api/quest?unclaimed=1&realm=europe";
    is scalar @$list, 0;

    $got_quest = http_json GET => "/api/quest/$quest->{_id}";
    is_deeply $got_quest->{likes}, ['bar'], 'joining means unliking';

    Dancer::session login => 'foo2';
    $response = dancer_response POST => "/api/quest/$quest->{_id}/join";
    is $response->status, 500;
    like $response->content, qr/unable to join a quest/;

    Dancer::session login => 'foo';
    http_json POST => "/api/quest/$quest->{_id}/invite", { params => {
        invitee => 'foo2',
    } };

    Dancer::session login => 'foo2';
    http_json POST => "/api/quest/$quest->{_id}/join";

    $got_quest = http_json GET => "/api/quest/$quest->{_id}";
    is_deeply $got_quest->{team}, ['foo', 'foo2'], '/join added user to the team';

    http_json POST => "/api/quest/$quest->{_id}/invite", { params => {
        invitee => 'bar',
    } };
    http_json POST => "/api/quest/$quest->{_id}/uninvite", { params => {
        invitee => 'bar',
    } };

    Dancer::session login => 'bar';
    $response = dancer_response POST => "/api/quest/$quest->{_id}/join";
    is $response->status, 500, 'invitation was cancelled';
    like $response->content, qr/unable to join a quest/, 'failed /join body';

    Dancer::session login => 'foo';
    $response = dancer_response POST => "/api/quest/$quest->{_id}/invite", { params => {
        invitee => 'nosuchuser',
    } };
    is $response->status, 500;
    like $response->content, qr/not found/;
}

sub watch_unwatch :Tests {
    http_json GET => "/api/fakeuser/foo";

    my $quest = http_json POST => '/api/quest', { params => {
        name => 'q1',
        realm => 'europe',
    } };

    my $response;

    $response = dancer_response POST => "/api/quest/$quest->{_id}/watch";
    is $response->status, 500;
    like $response->content, qr/unable to watch/;

    $response = dancer_response POST => "/api/quest/$quest->{_id}/unwatch";
    is $response->status, 500;
    like $response->content, qr/unable to unwatch/;

    http_json GET => "/api/fakeuser/bar";
    http_json POST => "/api/quest/$quest->{_id}/watch";

    my $got_quest = http_json GET => "/api/quest/$quest->{_id}";
    cmp_deeply $got_quest->{watchers}, ['bar'], 'bar is a watcher now';

    http_json GET => "/api/fakeuser/baz";
    http_json POST => "/api/quest/$quest->{_id}/watch";

    $got_quest = http_json GET => "/api/quest/$quest->{_id}";
    cmp_deeply $got_quest->{watchers}, ['bar', 'baz'], 'baz is a watcher now too';

    http_json POST => "/api/quest/$quest->{_id}/unwatch";
    $got_quest = http_json GET => "/api/quest/$quest->{_id}";
    cmp_deeply $got_quest->{watchers}, ['bar'], 'baz is not a watcher anymore';
}

sub checkin :Tests {
    http_json GET => "/api/fakeuser/foo";

    my $quest = http_json POST => '/api/quest', { params => {
        name => 'q1',
        realm => 'europe',
    } };

    http_json POST => "/api/quest/$quest->{_id}/checkin";

    my $got_quest = http_json GET => "/api/quest/$quest->{_id}";
    cmp_deeply $got_quest->{checkins}, [re('^\d+$')], 'checked in';
}

sub email_watchers :Tests {

    http_json GET => "/api/fakeuser/foo";
    register_email('foo' => { email => "foo\@example.com", notify_comments => 1 });

    my $quest = http_json POST => '/api/quest', { params => {
        name => 'q1',
        realm => 'europe',
    } };

    for my $user (qw/ bar baz buzz /) {
        http_json GET => "/api/fakeuser/$user";
        http_json POST => "/api/quest/$quest->{_id}/watch";
        register_email($user => { email => "$user\@example.com", notify_comments => 1 });
    }

    http_json POST => '/api/quest/'.$quest->{_id}.'/comment', { params => { body => 'hello to foo, bar and baz!' } };

    pumper('events2email')->run;
    my @deliveries = process_email_queue();
    is scalar @deliveries, 3;

    cmp_deeply
        [ sort map { $_->{successes}[0] } @deliveries ],
        [ sort map { "$_\@example.com" } qw( foo bar baz ) ];
}

sub atom :Tests {
    http_json GET => '/api/fakeuser/foo';

    http_json POST => '/api/quest', { params => {
        name => 'q1',
        status => 'open',
        realm => 'europe',
    } };
    http_json POST => '/api/quest', { params => {
        name => 'q2',
        status => 'open',
        realm => 'europe',
    } };

    # Regular Atom
    my $response = dancer_response GET => '/api/quest?fmt=atom&user=foo&realm=europe';
    is $response->status, 200;
    is exception { XML::LibXML->new->parse_string($response->content) }, undef;
}

sub manual_order :Tests {
    http_json GET => '/api/fakeuser/foo';

    my @quests;
    for (1..5) {
        push @quests, http_json POST => '/api/quest', { params => {
            name => "q$_",
            status => 'open',
            realm => 'europe',
        } };
    }

    http_json POST => '/api/quest/set_manual_order', { params => {
        'quest_ids[]' => [
            map { $_->{_id} } @quests
        ],
    } };
}

__PACKAGE__->new->runtests;
